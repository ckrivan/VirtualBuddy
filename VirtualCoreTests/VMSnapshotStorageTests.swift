import XCTest
import Virtualization
@testable import VirtualCore

final class VMSnapshotStorageTests: XCTestCase {
    private var bundleURL: URL!

    private let snapshotDisk = Data("disk contents when the snapshot was taken".utf8)
    private let snapshotAux = Data("aux storage when the snapshot was taken".utf8)
    private let stateData = Data("memory and device state".utf8)

    override func setUpWithError() throws {
        bundleURL = FileManager.default.temporaryDirectory
            .appending(path: "VMSnapshotStorageTests-\(UUID().uuidString).vbvm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        try snapshotDisk.write(to: path("Disk.img"))
        try snapshotAux.write(to: path("AuxiliaryStorage"))
        try Data("machine".utf8).write(to: path("MachineIdentifier"))
        try Data("hardware".utf8).write(to: path("HardwareModel"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundleURL)
    }

    // MARK: Helpers

    private func path(_ name: String) -> URL { bundleURL.appending(path: name) }

    private func readWorking(_ name: String) throws -> Data { try Data(contentsOf: path(name)) }

    private func makeStorage(_ fileSystem: SavedSessionFileSystem = DefaultSavedSessionFileSystem(), hostECID: UInt64 = 42) -> VMSnapshotStorage {
        VMSnapshotStorage(bundleURL: bundleURL, fileSystem: fileSystem, hostECID: hostECID)
    }

    private var resources: [SavedSessionCapturePlan.ResourceSource] {
        [
            .init(id: "disk", role: .disk, sourceURL: path("Disk.img"), workingPath: "Disk.img"),
            .init(id: "aux", role: .auxiliaryStorage, sourceURL: path("AuxiliaryStorage"), workingPath: "AuxiliaryStorage"),
            .init(id: "mid", role: .machineIdentifier, sourceURL: path("MachineIdentifier"), workingPath: "MachineIdentifier"),
            .init(id: "hw", role: .hardwareModel, sourceURL: path("HardwareModel"), workingPath: "HardwareModel")
        ]
    }

    private func makePlan() -> SavedSessionCapturePlan {
        SavedSessionCapturePlan(
            resources: resources,
            configuration: .default,
            runtimeDescription: SavedSessionRuntimeDescription(configuration: VZVirtualMachineConfiguration()),
            screenshotSourceURL: nil,
            wasPausedBeforeSave: false,
            memorySize: 1
        )
    }

    @discardableResult
    private func takeLiveSnapshot(with storage: VMSnapshotStorage, named name: String = "Live") throws -> VBSnapshot {
        let staged = try storage.stageLiveCapture(makePlan())
        try stateData.write(to: staged.stateFileURL)
        return try storage.publishLiveCapture(staged, named: name)
    }

    /// What the guest does after a snapshot was taken.
    private func modifyWorkingFiles(_ marker: String = "changed") throws {
        try Data("disk \(marker)".utf8).write(to: path("Disk.img"))
        try Data("aux \(marker)".utf8).write(to: path("AuxiliaryStorage"))
    }

    /// Runs a restore of the saved session the way the controller does when the virtual machine resumes.
    private func resumeSavedSession(with storage: VMSnapshotStorage) throws -> SavedSessionRestorePreparation {
        let preparation = try storage.sessions.prepareRestore()
        try storage.sessions.markConsumed(preparation)
        try storage.sessions.completeRestore()
        return preparation
    }

    private func snapshotsDirectoryEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path(VMSnapshotLayout.directoryName).path).sorted()
    }

    // MARK: Live Snapshots

    func testLiveSnapshotIsListedAndLeavesTheVirtualMachineAlone() throws {
        let storage = makeStorage()

        let snapshot = try takeLiveSnapshot(with: storage, named: "Before enrollment")

        XCTAssertEqual(snapshot.name, "Before enrollment")
        XCTAssertEqual(snapshot.kind, .live)
        XCTAssertNil(snapshot.problem)
        XCTAssertEqual(storage.list().map(\.id), [snapshot.id])

        XCTAssertEqual(try readWorking("Disk.img"), snapshotDisk)
        XCTAssertNil(storage.sessions.inspect(), "Taking a snapshot must not create a saved session")
    }

    func testLiveSnapshotCanBeRevertedToRepeatedly() throws {
        let storage = makeStorage()
        let snapshot = try takeLiveSnapshot(with: storage)

        var sessionIDs = Set<UUID>()

        for round in 1...3 {
            try modifyWorkingFiles("round \(round)")

            try storage.installAsSavedSession(snapshot.id)
            let preparation = try resumeSavedSession(with: storage)

            sessionIDs.insert(preparation.manifest.id)

            XCTAssertEqual(try readWorking("Disk.img"), snapshotDisk, "Round \(round)")
            XCTAssertEqual(try readWorking("AuxiliaryStorage"), snapshotAux, "Round \(round)")
            XCTAssertNil(storage.sessions.inspect(), "The clone of the snapshot is consumed by resuming")

            let listed = try XCTUnwrap(storage.list().first)
            XCTAssertEqual(listed.id, snapshot.id)
            XCTAssertNil(listed.problem, "Reverting must never consume the snapshot")
        }

        XCTAssertEqual(sessionIDs.count, 3, "Each revert resumes a session with its own identity")
        XCTAssertFalse(sessionIDs.contains(snapshot.id))
    }

    func testInstalledSnapshotIsResumedWithTheSnapshotsMemoryState() throws {
        let storage = makeStorage()
        let snapshot = try takeLiveSnapshot(with: storage)

        try storage.installAsSavedSession(snapshot.id)
        let preparation = try storage.sessions.prepareRestore()

        XCTAssertEqual(try Data(contentsOf: preparation.stateFileURL), stateData)
        XCTAssertNoThrow(try storage.sessions.cancelRestore())
    }

    func testRevertingAFailedRestoreLeavesTheSnapshotUsable() throws {
        let storage = makeStorage()
        let snapshot = try takeLiveSnapshot(with: storage)
        try modifyWorkingFiles()

        try storage.installAsSavedSession(snapshot.id)
        _ = try storage.sessions.prepareRestore()
        try storage.sessions.cancelRestore()
        try storage.sessions.discard()

        XCTAssertEqual(try readWorking("Disk.img"), Data("disk changed".utf8), "A cancelled restore puts the disks back")
        XCTAssertNil(storage.list().first?.problem)
    }

    func testInstallingRefusesToReplaceAnExistingSavedSession() throws {
        let storage = makeStorage()
        let snapshot = try takeLiveSnapshot(with: storage)

        let staged = try storage.sessions.stageCapture(makePlan())
        try stateData.write(to: staged.stateFileURL)
        try storage.sessions.publish(staged)

        XCTAssertThrowsError(try storage.installAsSavedSession(snapshot.id)) { error in
            guard case SavedSessionError.activeSessionConflict = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testSnapshotFromDifferentHostIsUnusable() throws {
        let snapshot = try takeLiveSnapshot(with: makeStorage(hostECID: 42))

        let otherHost = makeStorage(hostECID: 7)

        XCTAssertNotNil(otherHost.list().first?.problem)
        XCTAssertThrowsError(try otherHost.installAsSavedSession(snapshot.id))
    }

    func testSavedSessionCanBecomeASnapshotAndStaysSaved() throws {
        let storage = makeStorage()

        let staged = try storage.sessions.stageCapture(makePlan())
        try stateData.write(to: staged.stateFileURL)
        try storage.sessions.publish(staged)

        let snapshot = try storage.captureSavedSession(named: "From saved session")

        XCTAssertEqual(snapshot.kind, .live)
        XCTAssertNil(snapshot.problem)
        XCTAssertEqual(storage.sessions.inspect()?.isReady, true)

        try modifyWorkingFiles()
        try storage.sessions.discard()
        try storage.installAsSavedSession(snapshot.id)
        _ = try resumeSavedSession(with: storage)

        XCTAssertEqual(try readWorking("Disk.img"), snapshotDisk)
    }

    func testLiveCaptureThatFailsLeavesNothingBehind() throws {
        let fileSystem = FaultInjectingFileSystem()
        let storage = makeStorage(fileSystem)

        fileSystem.failingOperation = 4

        XCTAssertThrowsError(try storage.stageLiveCapture(makePlan()))
        XCTAssertTrue(storage.list().isEmpty)
        XCTAssertEqual(try snapshotsDirectoryEntries(), [])
    }

    // MARK: Disk Snapshots

    func testDiskSnapshotRevertRestoresDisksAndIdentity() throws {
        let storage = makeStorage()

        let snapshot = try storage.captureDisks(resources, screenshotSourceURL: nil, named: "Clean install")
        XCTAssertEqual(snapshot.kind, .disk)
        XCTAssertNil(snapshot.problem)

        try modifyWorkingFiles()
        try storage.revertDisks(to: snapshot.id)

        XCTAssertEqual(try readWorking("Disk.img"), snapshotDisk)
        XCTAssertEqual(try readWorking("AuxiliaryStorage"), snapshotAux)

        try modifyWorkingFiles("again")
        try storage.revertDisks(to: snapshot.id)
        XCTAssertEqual(try readWorking("Disk.img"), snapshotDisk, "A disk snapshot can be reverted to repeatedly")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundleURL.path).filter { $0.hasSuffix(VMSnapshotLayout.incomingSuffix) }
        XCTAssertEqual(leftovers, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.layout.revertJournalURL.path))
    }

    func testWritesToRevertedDisksNeverReachTheSnapshot() throws {
        let storage = makeStorage()
        let snapshot = try storage.captureDisks(resources, screenshotSourceURL: nil, named: "Base")

        try storage.revertDisks(to: snapshot.id)

        /// Write in place, the way the guest does, rather than replacing the file.
        let handle = try FileHandle(forWritingTo: path("Disk.img"))
        try handle.write(contentsOf: Data("GUEST".utf8))
        try handle.close()

        try storage.revertDisks(to: snapshot.id)
        XCTAssertEqual(try readWorking("Disk.img"), snapshotDisk)
    }

    func testDiskRevertInterruptedAtAnyStepIsFinishedOrNeverStarted() throws {
        let probe = FaultInjectingFileSystem()
        let probeStorage = makeStorage(probe)
        let snapshot = try probeStorage.captureDisks(resources, screenshotSourceURL: nil, named: "Base")

        let before = probe.operationCount
        try probeStorage.revertDisks(to: snapshot.id)
        let revertOperations = probe.operationCount - before

        XCTAssertGreaterThan(revertOperations, 4)

        for step in 1...revertOperations {
            try modifyWorkingFiles("step \(step)")

            let crashing = FaultInjectingFileSystem()
            crashing.mode = .crash
            crashing.failingOperation = step

            XCTAssertThrowsError(try makeStorage(crashing).revertDisks(to: snapshot.id), "Step \(step)")

            /// What the app does the next time it's about to use the disks.
            try makeStorage().recoverInterruptedRevert()

            let disk = try readWorking("Disk.img")
            let aux = try readWorking("AuxiliaryStorage")

            let reverted = disk == snapshotDisk && aux == snapshotAux
            let untouched = disk == Data("disk step \(step)".utf8) && aux == Data("aux step \(step)".utf8)

            XCTAssertTrue(reverted || untouched, "Step \(step) left a mix of reverted and current files")

            let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundleURL.path).filter { $0.hasSuffix(VMSnapshotLayout.incomingSuffix) }
            XCTAssertEqual(leftovers, [], "Step \(step)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: probeStorage.layout.revertJournalURL.path), "Step \(step)")
        }
    }

    func testDiskCaptureThatFailsAtAnyStepLeavesNothingBehind() throws {
        let probe = FaultInjectingFileSystem()
        _ = try makeStorage(probe).captureDisks(resources, screenshotSourceURL: nil, named: "Probe")
        let captureOperations = probe.operationCount
        try FileManager.default.removeItem(at: path(VMSnapshotLayout.directoryName))

        for step in 1...captureOperations {
            let failing = FaultInjectingFileSystem()
            failing.failingOperation = step

            let storage = makeStorage(failing)

            do {
                _ = try storage.captureDisks(resources, screenshotSourceURL: nil, named: "Step \(step)")
                /// Failing to flush after publishing doesn't fail the capture.
                XCTAssertEqual(storage.list().count, 1, "Step \(step)")
                try storage.delete(XCTUnwrap(storage.list().first).id)
            } catch {
                XCTAssertTrue(storage.list().isEmpty, "Step \(step)")
            }

            let entries = (try? snapshotsDirectoryEntries()) ?? []
            XCTAssertEqual(entries.filter { $0.hasPrefix(VMSnapshotLayout.stagingPrefix) }, [], "Step \(step)")
            XCTAssertEqual(try readWorking("Disk.img"), snapshotDisk, "Step \(step)")
        }
    }

    func testRevertingALiveSnapshotAsDisksIsRefused() throws {
        let storage = makeStorage()
        let live = try takeLiveSnapshot(with: storage)
        let disk = try storage.captureDisks(resources, screenshotSourceURL: nil, named: "Disk")

        XCTAssertThrowsError(try storage.revertDisks(to: live.id))
        XCTAssertThrowsError(try storage.installAsSavedSession(disk.id))
    }

    // MARK: Managing

    func testSnapshotsAreListedOldestFirstAndCanBeRenamedAndDeleted() throws {
        let storage = makeStorage()

        let first = try storage.captureDisks(resources, screenshotSourceURL: nil, named: "First")
        let second = try takeLiveSnapshot(with: storage, named: "Second")

        XCTAssertEqual(storage.list().map(\.id), [first.id, second.id])

        try storage.rename(first.id, to: "Renamed")
        XCTAssertEqual(storage.list().first?.name, "Renamed")
        XCTAssertNil(storage.list().first?.problem)

        try storage.delete(first.id)
        XCTAssertEqual(storage.list().map(\.id), [second.id])
        XCTAssertEqual(try snapshotsDirectoryEntries(), [second.id.uuidString])
    }

    func testDamagedSnapshotIsListedButCantBeRevertedTo() throws {
        let storage = makeStorage()
        let snapshot = try storage.captureDisks(resources, screenshotSourceURL: nil, named: "Base")

        let resourcesURL = storage.layout.packageURL(for: snapshot.id).appending(path: SavedSessionLayout.resourcesDirectoryName)
        let disk = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: resourcesURL.path).first { $0.hasPrefix("disk") })
        try Data("truncated".utf8).write(to: resourcesURL.appending(path: disk))

        try modifyWorkingFiles()

        XCTAssertNotNil(storage.list().first?.problem)
        XCTAssertThrowsError(try storage.revertDisks(to: snapshot.id))
        XCTAssertEqual(try readWorking("Disk.img"), Data("disk changed".utf8), "A refused revert changes nothing")
    }

    func testSnapshotThatEscapesTheBundleIsRefused() throws {
        let storage = makeStorage()
        let snapshot = try storage.captureDisks(resources, screenshotSourceURL: nil, named: "Base")

        let infoURL = storage.layout.packageURL(for: snapshot.id).appending(path: VMSnapshotLayout.infoFileName)
        var info = try PropertyListDecoder().decode(VMSnapshotInfo.self, from: Data(contentsOf: infoURL))
        info.resources?[0].workingPath = "../Escaped.img"
        try PropertyListEncoder().encode(info).write(to: infoURL)

        XCTAssertNotNil(storage.list().first?.problem)
        XCTAssertThrowsError(try storage.revertDisks(to: snapshot.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.deletingLastPathComponent().appending(path: "Escaped.img").path))
    }

    // MARK: Layout

    func testSnapshotLayoutStaysOutOfEverythingElse() {
        XCTAssertFalse(SavedSessionLayout.isPermittedWorkingPath(VMSnapshotLayout.directoryName))
        XCTAssertTrue(SavedSessionLayout.isTransientName("Disk.img" + VMSnapshotLayout.incomingSuffix))
        XCTAssertFalse(SavedSessionLayout.isTransientName(VMSnapshotLayout.directoryName), "Duplicating a virtual machine keeps its snapshots")
        XCTAssertTrue(SavedSessionLayout.isPermittedWorkingPath(SavedSessionLayout.linuxNVRAMWorkingPath))
    }
}
