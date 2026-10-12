import Testing
import Foundation
import Virtualization
@testable import VirtualCore

@MainActor
final class VMControllerSnapshotTests {
    private let directoryURL: URL
    private let snapshotDisk = Data("disk at snapshot time".utf8)

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "VMControllerSnapshotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    // MARK: Helpers

    private func makeVirtualMachine() throws -> VBVirtualMachine {
        var model = try VBVirtualMachine(
            bundleURL: directoryURL.appending(path: "Test.\(VBVirtualMachine.bundleExtension)", directoryHint: .isDirectory),
            isNewInstall: true
        )
        model.metadata.installFinished = true
        try model.saveMetadata()

        for device in model.configuration.hardware.storageDevices {
            try snapshotDisk.write(to: model.diskImageURL(for: device))
        }
        try Data("aux".utf8).write(to: model.auxiliaryStorageURL)
        try Data("machine identifier".utf8).write(to: model.machineIdentifierURL)
        try Data("hardware model".utf8).write(to: model.hardwareModelURL)

        return model
    }

    private func bootDiskURL(of model: VBVirtualMachine) throws -> URL {
        model.diskImageURL(for: try #require(model.configuration.hardware.storageDevices.first))
    }

    private func saveSession(in model: VBVirtualMachine) throws {
        let storage = SavedSessionStorage(bundleURL: model.bundleURL)

        let plan = SavedSessionCapturePlan(
            resources: try model.diskSnapshotResources(),
            configuration: model.configuration,
            runtimeDescription: .init(configuration: .init()),
            screenshotSourceURL: nil,
            wasPausedBeforeSave: false,
            memorySize: 1
        )

        let staged = try storage.stageCapture(plan)
        try Data("state".utf8).write(to: staged.stateFileURL)
        try storage.publish(staged)
    }

    private func makeController(for model: VBVirtualMachine) throws -> VMController {
        VMController(with: try VBVirtualMachine(bundleURL: model.bundleURL, isNewInstall: false, createIfNeeded: false), library: .preview)
    }

    // MARK: Tests

    @Test func shutDownVirtualMachineTakesDiskSnapshots() throws {
        let controller = try makeController(for: try makeVirtualMachine())

        #expect(controller.snapshotCapture == .disk)
        #expect(controller.snapshots.isEmpty)
    }

    @Test func takingAndRevertingADiskSnapshot() async throws {
        let model = try makeVirtualMachine()
        let controller = try makeController(for: model)

        let snapshot = try await controller.takeSnapshot(named: "Clean")

        #expect(controller.snapshots.map(\.id) == [snapshot.id])
        #expect(snapshot.kind == .disk)
        #expect(controller.isPerformingSnapshotOperation == false)

        try Data("disk after changes".utf8).write(to: try bootDiskURL(of: model))

        try await controller.revertToSnapshot(snapshot.id)

        #expect(try Data(contentsOf: try bootDiskURL(of: model)) == snapshotDisk)
        #expect(controller.state.isIdle)
        #expect(controller.snapshots.map(\.id) == [snapshot.id])
    }

    @Test func revertingThrowsAwayTheSavedSession() async throws {
        let model = try makeVirtualMachine()
        let controller = try makeController(for: model)
        let snapshot = try await controller.takeSnapshot(named: "Clean")

        try Data("disk after changes".utf8).write(to: try bootDiskURL(of: model))
        try saveSession(in: model)
        controller.reloadSavedSession()
        #expect(controller.state.isSaved)

        try await controller.revertToSnapshot(snapshot.id)

        #expect(controller.savedSession == nil)
        #expect(controller.state.isIdle)
        #expect(try Data(contentsOf: try bootDiskURL(of: model)) == snapshotDisk)
    }

    @Test func savedVirtualMachineSnapshotsItsSavedSession() async throws {
        let model = try makeVirtualMachine()
        try saveSession(in: model)
        let controller = try makeController(for: model)

        #expect(controller.snapshotCapture == .savedSession)

        let snapshot = try await controller.takeSnapshot(named: "Suspended")

        #expect(snapshot.kind == .live)
        #expect(snapshot.isUsable)
        #expect(controller.state.isSaved, "Taking a snapshot keeps the saved session")
    }

    @Test func renamingAndDeletingUpdateTheList() async throws {
        let controller = try makeController(for: try makeVirtualMachine())
        let snapshot = try await controller.takeSnapshot(named: "Old Name")

        try await controller.renameSnapshot(snapshot.id, to: "New Name")
        #expect(controller.snapshots.first?.name == "New Name")

        try await controller.deleteSnapshot(snapshot.id)
        #expect(controller.snapshots.isEmpty)
    }

    @Test func snapshotsAreLoadedWhenTheControllerIsCreated() async throws {
        let model = try makeVirtualMachine()
        let snapshot = try await makeController(for: model).takeSnapshot(named: "Persisted")

        let reopened = try makeController(for: model)

        #expect(reopened.snapshots.map(\.id) == [snapshot.id])
    }

    @Test func revertingToAMissingSnapshotChangesNothing() async throws {
        let model = try makeVirtualMachine()
        let controller = try makeController(for: model)
        try Data("disk after changes".utf8).write(to: try bootDiskURL(of: model))

        await #expect(throws: VMSnapshotError.self) {
            try await controller.revertToSnapshot(UUID())
        }

        #expect(try Data(contentsOf: try bootDiskURL(of: model)) == Data("disk after changes".utf8))
    }

    @Test func externalDiskImagesPreventDiskSnapshots() throws {
        var model = try makeVirtualMachine()
        model.configuration.hardware.storageDevices.append(VBStorageDevice(
            isBootVolume: false,
            isEnabled: true,
            isReadOnly: false,
            isUSBMassStorageDevice: false,
            backing: .customImage(directoryURL.appending(path: "External.img"))
        ))
        try model.saveMetadata()

        let controller = try makeController(for: model)

        guard case .unavailable = controller.snapshotCapture else {
            Issue.record("Expected snapshots to be unavailable, got \(controller.snapshotCapture)")
            return
        }
    }

    @Test func linuxFirmwareStoreIsCapturedAndReverted() throws {
        let model = try makeVirtualMachine()
        let nvramURL = model.metadataDirectoryURL.appending(path: "nvram")
        try Data("boot entries".utf8).write(to: nvramURL)

        let resources = try model.diskSnapshotResources()
        #expect(resources.contains { $0.workingPath == SavedSessionLayout.linuxNVRAMWorkingPath })

        let storage = VMSnapshotStorage(bundleURL: model.bundleURL)
        let snapshot = try storage.captureDisks(resources, screenshotSourceURL: nil, named: "Linux")

        try Data("changed boot entries".utf8).write(to: nvramURL)
        try storage.revertDisks(to: snapshot.id)

        #expect(try Data(contentsOf: nvramURL) == Data("boot entries".utf8))
    }
}
