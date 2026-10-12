import Foundation
import OSLog

/// A point-in-time copy of a virtual machine that can be reverted to any number of times.
///
/// Unlike a saved session, which is consumed when the virtual machine resumes from it, a snapshot is never
/// modified by reverting to it.
public struct VBSnapshot: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Memory, device state and disks. Reverting resumes the guest exactly where it was.
        case live
        /// Disks only, captured while the virtual machine was shut down. Reverting leaves it shut down.
        case disk
    }

    public var id: UUID
    public var name: String
    public var date: Date
    public var kind: Kind
    public var screenshotURL: URL?
    /// Why the snapshot can't be reverted to, `nil` if it can.
    public var problem: String?

    public var isUsable: Bool { problem == nil }
}

/// Stored in every snapshot package next to the saved session files (live) or the disk clones (disk).
struct VMSnapshotInfo: Codable, Hashable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var id: UUID
    var name: String
    var date: Date
    var kind: VBSnapshot.Kind
    var screenshotFileName: String?
    /// The resources of a disk snapshot. A live snapshot lists its resources in its saved session manifest.
    var resources: [SavedSessionManifest.Resource]?
}

/// Durable record of a disk revert, so that one interrupted halfway is finished before the virtual machine runs.
struct VMSnapshotRevertJournal: Codable, Hashable, Sendable {
    var snapshotID: UUID
}

/// Locations of the snapshots of a virtual machine.
///
/// Every snapshot is a directory named after its identifier. Names that start with a dot are work in progress and are never listed.
struct VMSnapshotLayout: Sendable {
    static let directoryName = "Snapshots"
    static let infoFileName = "Snapshot.plist"
    static let stagingPrefix = ".staging-"
    static let obsoletePrefix = ".obsolete-"
    static let revertJournalName = ".revert.plist"
    /// Appended to a working resource while its replacement from a snapshot is being prepared next to it.
    static let incomingSuffix = ".snapshot-incoming"

    let bundleURL: URL

    var directoryURL: URL { bundleURL.appending(path: Self.directoryName, directoryHint: .isDirectory) }
    var revertJournalURL: URL { directoryURL.appending(path: Self.revertJournalName) }

    func packageURL(for id: UUID) -> URL {
        directoryURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func stagingURL(for id: UUID) -> URL {
        directoryURL.appending(path: Self.stagingPrefix + id.uuidString, directoryHint: .isDirectory)
    }

    func obsoleteURL(for id: UUID) -> URL {
        directoryURL.appending(path: Self.obsoletePrefix + id.uuidString, directoryHint: .isDirectory)
    }
}

public enum VMSnapshotError: LocalizedError {
    case notFound
    case unusable(String)
    case unsupportedFormat
    case wrongKind

    public var errorDescription: String? {
        switch self {
        case .notFound: "The snapshot doesn't exist anymore."
        case .unusable(let reason): "The snapshot can't be used. \(reason)"
        case .unsupportedFormat: "The snapshot was created by a newer version of VirtualBuddy."
        case .wrongKind: "This operation isn't available for this kind of snapshot."
        }
    }
}

/// Reads and writes the snapshots of a virtual machine.
///
/// Live snapshots are saved session packages with a name. Reverting to one installs a clone of it as the
/// virtual machine's saved session and resumes that, so everything that keeps resuming safe applies to snapshots too.
/// Disk snapshots are clones of the virtual machine's disks and identity files, which reverting clones back into place.
struct VMSnapshotStorage: Sendable {
    let layout: VMSnapshotLayout
    let sessions: SavedSessionStorage
    let fileSystem: SavedSessionFileSystem

    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "VMSnapshotStorage")

    private static let encoder = PropertyListEncoder()
    private static let decoder = PropertyListDecoder()

    init(bundleURL: URL, fileSystem: SavedSessionFileSystem = DefaultSavedSessionFileSystem(), hostECID: UInt64? = ProcessInfo.processInfo.machineECID) {
        self.layout = VMSnapshotLayout(bundleURL: bundleURL)
        self.sessions = SavedSessionStorage(bundleURL: bundleURL, fileSystem: fileSystem, hostECID: hostECID)
        self.fileSystem = fileSystem
    }

    // MARK: Listing

    /// Every snapshot, oldest first. Snapshots that can't be used are included with the reason.
    func list() -> [VBSnapshot] {
        guard let urls = try? fileSystem.contentsOfDirectory(at: layout.directoryURL) else { return [] }

        return urls
            .compactMap { url -> VBSnapshot? in
                guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
                return describe(id)
            }
            .sorted { $0.date < $1.date }
    }

    private func describe(_ id: UUID) -> VBSnapshot {
        let packageURL = layout.packageURL(for: id)

        let info: VMSnapshotInfo
        do {
            info = try readInfo(id)
        } catch {
            return VBSnapshot(id: id, name: "Damaged Snapshot", date: packageURL.creationDate, kind: .disk, problem: error.localizedDescription)
        }

        var snapshot = VBSnapshot(
            id: id,
            name: info.name,
            date: info.date,
            kind: info.kind,
            screenshotURL: info.screenshotFileName.map { packageURL.appending(path: $0) }
        )

        do {
            try validate(info)
        } catch {
            snapshot.problem = error.localizedDescription
        }

        return snapshot
    }

    // MARK: Capturing

    /// Stages a live snapshot. The framework state file must then be written to the staged capture's state file URL
    /// while the virtual machine is still paused, before ``publishLiveCapture(_:named:)``.
    func stageLiveCapture(_ plan: SavedSessionCapturePlan) throws -> SavedSessionStagedCapture {
        try prepareDirectory()
        return try sessions.stageCapture(plan, at: layout.stagingURL(for: plan.sessionID))
    }

    func publishLiveCapture(_ staged: SavedSessionStagedCapture, named name: String) throws -> VBSnapshot {
        let id = staged.plan.sessionID

        do {
            let info = VMSnapshotInfo(
                formatVersion: VMSnapshotInfo.currentFormatVersion,
                id: id,
                name: name,
                date: .now,
                kind: .live,
                screenshotFileName: staged.screenshotFileName
            )
            try writeInfo(info, in: staged.stagingURL)
        } catch {
            abandon(staged)
            throw error
        }

        _ = try sessions.publish(staged, to: layout.packageURL(for: id))

        return describe(id)
    }

    func abandon(_ staged: SavedSessionStagedCapture) {
        try? fileSystem.remove(staged.stagingURL)
    }

    /// Clones the disks and identity files of a virtual machine that isn't running.
    func captureDisks(_ resources: [SavedSessionCapturePlan.ResourceSource], screenshotSourceURL: URL?, named name: String) throws -> VBSnapshot {
        try prepareDirectory()

        let id = UUID()
        let stagingURL = layout.stagingURL(for: id)

        do {
            let resourcesURL = stagingURL.appending(path: SavedSessionLayout.resourcesDirectoryName, directoryHint: .isDirectory)
            try fileSystem.createDirectory(resourcesURL)

            var captured = [SavedSessionManifest.Resource]()

            for (index, source) in resources.enumerated() {
                try Task.checkCancellation()

                let name = "\(source.role.rawValue)-\(index)"

                guard let size = fileSystem.byteCount(of: source.sourceURL) else {
                    throw SavedSessionError.missingResource(source.sourceURL.lastPathComponent)
                }

                try fileSystem.clone(from: source.sourceURL, to: resourcesURL.appending(path: name))

                captured.append(SavedSessionManifest.Resource(
                    id: source.id,
                    role: source.role,
                    packagePath: "\(SavedSessionLayout.resourcesDirectoryName)/\(name)",
                    workingPath: source.workingPath,
                    byteCount: size
                ))
            }

            let screenshotFileName = cloneScreenshot(from: screenshotSourceURL, into: stagingURL)

            let info = VMSnapshotInfo(
                formatVersion: VMSnapshotInfo.currentFormatVersion,
                id: id,
                name: name,
                date: .now,
                kind: .disk,
                screenshotFileName: screenshotFileName,
                resources: captured
            )
            try writeInfo(info, in: stagingURL)
            try validate(info, in: stagingURL)

            try publish(stagingURL: stagingURL, id: id)
        } catch {
            try? fileSystem.remove(stagingURL)
            throw error
        }

        return describe(id)
    }

    /// Turns a copy of the virtual machine's saved session into a live snapshot. The saved session is left as it is.
    func captureSavedSession(named name: String) throws -> VBSnapshot {
        try prepareDirectory()

        let manifest = try sessions.readManifest(inPackageAt: sessions.layout.packageURL)
        try sessions.validate(manifest, in: sessions.layout.packageURL)

        let id = UUID()
        let stagingURL = layout.stagingURL(for: id)

        do {
            try fileSystem.clone(from: sessions.layout.packageURL, to: stagingURL)

            let info = VMSnapshotInfo(
                formatVersion: VMSnapshotInfo.currentFormatVersion,
                id: id,
                name: name,
                date: manifest.date,
                kind: .live,
                screenshotFileName: manifest.screenshotFileName
            )
            try writeInfo(info, in: stagingURL)
            try validate(info, in: stagingURL)

            try publish(stagingURL: stagingURL, id: id)
        } catch {
            try? fileSystem.remove(stagingURL)
            throw error
        }

        return describe(id)
    }

    // MARK: Managing

    func rename(_ id: UUID, to name: String) throws {
        var info = try readInfo(id)
        info.name = name
        try writeInfo(info, in: layout.packageURL(for: id))
    }

    func delete(_ id: UUID) throws {
        let packageURL = layout.packageURL(for: id)
        guard fileSystem.exists(packageURL) else { return }

        let obsoleteURL = layout.obsoleteURL(for: id)
        try fileSystem.remove(obsoleteURL)
        try fileSystem.move(from: packageURL, to: obsoleteURL, replacingExisting: false)
        try? fileSystem.synchronizeDirectory(layout.directoryURL)

        do {
            try fileSystem.remove(obsoleteURL)
        } catch {
            /// Leftovers are never listed, and are collected the next time snapshots are written.
            logger.warning("Failed to remove deleted snapshot: \(error, privacy: .public)")
        }
    }

    // MARK: Reverting

    /// Installs a clone of a live snapshot as the virtual machine's saved session. Resuming the saved session completes the revert.
    ///
    /// The virtual machine must not have a saved session, and must not be running.
    func installAsSavedSession(_ id: UUID) throws {
        let info = try readInfo(id)
        guard info.kind == .live else { throw VMSnapshotError.wrongKind }
        try validate(info)

        try sessions.recover()

        guard !fileSystem.exists(sessions.layout.packageURL), !fileSystem.exists(sessions.layout.transactionURL) else {
            throw SavedSessionError.activeSessionConflict
        }

        let sessionID = UUID()
        let stagingURL = sessions.layout.stagingURL(for: sessionID)

        do {
            try fileSystem.clone(from: layout.packageURL(for: id), to: stagingURL)
            try fileSystem.remove(stagingURL.appending(path: VMSnapshotLayout.infoFileName))

            /// Every session that's resumed gets its own identity, even when it comes from the same snapshot as a previous one.
            var manifest = try sessions.readManifest(inPackageAt: stagingURL)
            manifest.id = sessionID
            try fileSystem.writeDurably(try Self.encoder.encode(manifest), to: stagingURL.appending(path: SavedSessionLayout.manifestFileName))

            try sessions.validate(manifest, in: stagingURL)

            try fileSystem.synchronizeDirectory(stagingURL)
            try fileSystem.move(from: stagingURL, to: sessions.layout.packageURL, replacingExisting: false)
            try? fileSystem.synchronizeDirectory(layout.bundleURL)
        } catch {
            try? fileSystem.remove(stagingURL)
            throw error
        }
    }

    /// Replaces the virtual machine's disks and identity files with clones from a disk snapshot.
    ///
    /// Every clone is prepared next to the file it replaces before anything is replaced. If the replacements are interrupted,
    /// ``recoverInterruptedRevert()`` finishes them. The virtual machine must not be running.
    func revertDisks(to id: UUID) throws {
        let info = try readInfo(id)
        guard info.kind == .disk else { throw VMSnapshotError.wrongKind }
        try validate(info)

        try fileSystem.writeDurably(try Self.encoder.encode(VMSnapshotRevertJournal(snapshotID: id)), to: layout.revertJournalURL)

        try performDiskRevert(info)

        try fileSystem.remove(layout.revertJournalURL)
    }

    /// Finishes a disk revert that was interrupted. Must only be called while the virtual machine isn't running.
    func recoverInterruptedRevert() throws {
        guard fileSystem.exists(layout.revertJournalURL) else { return }

        let journal = try Self.decoder.decode(VMSnapshotRevertJournal.self, from: fileSystem.read(layout.revertJournalURL))

        if let info = try? readInfo(journal.snapshotID), (try? validate(info)) != nil {
            logger.notice("Finishing interrupted revert to snapshot \(journal.snapshotID, privacy: .public)")
            try performDiskRevert(info)
        } else {
            logger.error("Snapshot of interrupted revert is gone, removing leftovers")
            try removeIncomingFiles()
        }

        try fileSystem.remove(layout.revertJournalURL)
    }

    private func performDiskRevert(_ info: VMSnapshotInfo) throws {
        let packageURL = layout.packageURL(for: info.id)
        let resources = info.resources ?? []

        let targets = try resources.map { resource in
            let workingURL = try sessions.layout.workingURL(for: resource.workingPath)
            let incomingURL = workingURL.deletingLastPathComponent().appending(path: workingURL.lastPathComponent + VMSnapshotLayout.incomingSuffix)
            return (resource: resource, workingURL: workingURL, incomingURL: incomingURL)
        }

        for target in targets {
            try fileSystem.remove(target.incomingURL)
            try fileSystem.createDirectory(target.workingURL.deletingLastPathComponent())
            try fileSystem.clone(from: packageURL.appending(path: target.resource.packagePath), to: target.incomingURL)
        }

        for target in targets {
            try fileSystem.move(from: target.incomingURL, to: target.workingURL, replacingExisting: true)
        }

        try fileSystem.synchronizeDirectory(layout.bundleURL)
    }

    private func removeIncomingFiles() throws {
        let directories = [layout.bundleURL, VBVirtualMachine.metadataDirectoryURL(for: layout.bundleURL)]

        for directory in directories where fileSystem.exists(directory) {
            for url in try fileSystem.contentsOfDirectory(at: directory) where url.lastPathComponent.hasSuffix(VMSnapshotLayout.incomingSuffix) {
                try fileSystem.remove(url)
            }
        }
    }

    // MARK: Internals

    private func prepareDirectory() throws {
        try fileSystem.createDirectory(layout.directoryURL)

        for url in try fileSystem.contentsOfDirectory(at: layout.directoryURL) {
            let name = url.lastPathComponent
            if name.hasPrefix(VMSnapshotLayout.stagingPrefix) || name.hasPrefix(VMSnapshotLayout.obsoletePrefix) {
                try fileSystem.remove(url)
            }
        }
    }

    private func publish(stagingURL: URL, id: UUID) throws {
        try fileSystem.synchronizeDirectory(stagingURL)
        try fileSystem.move(from: stagingURL, to: layout.packageURL(for: id), replacingExisting: false)
        try? fileSystem.synchronizeDirectory(layout.directoryURL)
    }

    private func cloneScreenshot(from sourceURL: URL?, into packageURL: URL) -> String? {
        guard let sourceURL, fileSystem.exists(sourceURL) else { return nil }

        /// A screenshot is only presentation, failing to copy one must not fail the snapshot.
        do {
            try fileSystem.clone(from: sourceURL, to: packageURL.appending(path: SavedSessionLayout.screenshotFileName))
            return SavedSessionLayout.screenshotFileName
        } catch {
            logger.warning("Failed to copy screenshot into snapshot: \(error, privacy: .public)")
            return nil
        }
    }

    private func readInfo(_ id: UUID) throws -> VMSnapshotInfo {
        let packageURL = layout.packageURL(for: id)

        guard fileSystem.exists(packageURL) else { throw VMSnapshotError.notFound }
        guard !fileSystem.isSymbolicLink(packageURL) else {
            throw VMSnapshotError.unusable("The snapshot is not stored inside the virtual machine.")
        }

        let info: VMSnapshotInfo
        do {
            info = try Self.decoder.decode(VMSnapshotInfo.self, from: fileSystem.read(packageURL.appending(path: VMSnapshotLayout.infoFileName)))
        } catch {
            throw VMSnapshotError.unusable("Its description could not be read.")
        }

        guard info.formatVersion <= VMSnapshotInfo.currentFormatVersion else { throw VMSnapshotError.unsupportedFormat }
        guard info.id == id else { throw VMSnapshotError.unusable("Its description belongs to a different snapshot.") }

        return info
    }

    private func writeInfo(_ info: VMSnapshotInfo, in packageURL: URL) throws {
        try fileSystem.writeDurably(try Self.encoder.encode(info), to: packageURL.appending(path: VMSnapshotLayout.infoFileName))
    }

    private func validate(_ info: VMSnapshotInfo) throws {
        try validate(info, in: layout.packageURL(for: info.id))
    }

    private func validate(_ info: VMSnapshotInfo, in packageURL: URL) throws {
        if let screenshotFileName = info.screenshotFileName, !SavedSessionLayout.isPermittedPackagePath(screenshotFileName) {
            throw VMSnapshotError.unusable("Its description refers to files outside of the snapshot.")
        }

        switch info.kind {
        case .live:
            let manifest = try sessions.readManifest(inPackageAt: packageURL)
            try sessions.validate(manifest, in: packageURL)

        case .disk:
            guard let resources = info.resources, !resources.isEmpty else {
                throw VMSnapshotError.unusable("It doesn't contain any disks.")
            }

            for resource in resources {
                guard SavedSessionLayout.isPermittedPackagePath(resource.packagePath) else {
                    throw VMSnapshotError.unusable("Its description refers to files outside of the snapshot.")
                }
                _ = try sessions.layout.workingURL(for: resource.workingPath)

                guard fileSystem.byteCount(of: packageURL.appending(path: resource.packagePath)) == resource.byteCount else {
                    throw SavedSessionError.resourceSizeMismatch(resource.packagePath)
                }
            }
        }
    }
}

// MARK: - Resources

extension VBVirtualMachine {
    /// The files a disk snapshot captures: every managed disk image, and the identity and firmware files that exist.
    func diskSnapshotResources() throws -> [SavedSessionCapturePlan.ResourceSource] {
        var resources = [SavedSessionCapturePlan.ResourceSource]()

        for device in configuration.hardware.storageDevices where device.isEnabled {
            guard case .managedImage(let image) = device.backing else {
                throw SavedSessionError.notEligible(.externalDiskImage(device.displayName))
            }

            let url = diskImageURL(for: image)
            resources.append(.init(id: device.id, role: .disk, sourceURL: url, workingPath: url.lastPathComponent))
        }

        let optional: [(String, SavedSessionManifest.Role, URL, String)] = [
            ("auxiliaryStorage", .auxiliaryStorage, auxiliaryStorageURL, auxiliaryStorageURL.lastPathComponent),
            ("machineIdentifier", .machineIdentifier, machineIdentifierURL, machineIdentifierURL.lastPathComponent),
            ("hardwareModel", .hardwareModel, hardwareModelURL, hardwareModelURL.lastPathComponent),
            ("nvram", .auxiliaryStorage, metadataDirectoryURL.appending(path: "nvram"), SavedSessionLayout.linuxNVRAMWorkingPath),
        ]

        for (id, role, url, workingPath) in optional where FileManager.default.fileExists(atPath: url.path) {
            resources.append(.init(id: id, role: role, sourceURL: url, workingPath: workingPath))
        }

        return resources
    }

    /// The screenshot or thumbnail that best shows the virtual machine, if it has one.
    var snapshotScreenshotURL: URL? {
        [VBVirtualMachine.screenshotFileName, VBVirtualMachine.thumbnailFileName]
            .map { metadataFileURL($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
