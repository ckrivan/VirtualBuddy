import SwiftUI
import VirtualCore

/// Toolbar button that shows the snapshots of the virtual machine.
struct SnapshotsToolbarButton: View {
    @EnvironmentObject private var controller: VMController

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "camera.on.rectangle")
        }
        .help("Snapshots")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SnapshotsPanel()
                .environmentObject(controller)
        }
    }
}

/// Lists the snapshots of a virtual machine, and takes, reverts to, renames and deletes them.
struct SnapshotsPanel: View {
    @EnvironmentObject private var controller: VMController

    @State private var newName = ""
    @State private var errorMessage: String?
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var renamingID: VBSnapshot.ID?
    @State private var renameText = ""

    private struct PendingConfirmation: Equatable {
        enum Action { case revert, delete }
        var id: VBSnapshot.ID
        var action: Action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)

            Divider()

            if controller.snapshots.isEmpty {
                emptyState
            } else {
                list
            }

            if let errorMessage {
                Divider()

                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
        }
        .frame(width: 380)
        .disabled(controller.isPerformingSnapshotOperation)
        .onAppear { controller.reloadSnapshots() }
    }

    // MARK: Taking

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Snapshots")
                    .font(.headline)

                Spacer()

                if controller.isPerformingSnapshotOperation {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                TextField(defaultName, text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(takeSnapshot)

                Button("Take Snapshot", action: takeSnapshot)
                    .disabled(!canTake)
            }

            Text(captureDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canTake: Bool {
        if case .unavailable = controller.snapshotCapture { return false }
        return true
    }

    private var captureDescription: String {
        switch controller.snapshotCapture {
        case .live: "Captures memory and disks. The virtual machine pauses briefly, then keeps running."
        case .savedSession: "Captures the saved session, including memory and disks."
        case .disk: "Captures the disks. Take a snapshot while the virtual machine runs to capture its memory too."
        case .unavailable(let reason): reason
        }
    }

    private var defaultName: String {
        Date.now.formatted(.dateTime.month().day().hour().minute())
    }

    private func takeSnapshot() {
        guard canTake else { return }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? defaultName : trimmed

        perform {
            try await controller.takeSnapshot(named: name)
            newName = ""
        }
    }

    // MARK: Listing

    private var emptyState: some View {
        Text("No snapshots yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(24)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(controller.snapshots.reversed()) { snapshot in
                    row(for: snapshot)

                    if snapshot.id != controller.snapshots.first?.id {
                        Divider()
                            .padding(.leading, 76)
                    }
                }
            }
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func row(for snapshot: VBSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SnapshotThumbnail(snapshot: snapshot)

            VStack(alignment: .leading, spacing: 3) {
                if renamingID == snapshot.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(of: snapshot) }
                        .onExitCommand { renamingID = nil }
                } else {
                    Text(snapshot.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { beginRename(of: snapshot) }
                }

                Label {
                    Text(snapshot.date, format: .dateTime.month().day().year().hour().minute())
                } icon: {
                    Image(systemName: snapshot.kind == .live ? "memorychip" : "internaldrive")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(snapshot.kind == .live ? "Memory and disks" : "Disks only")

                if let problem = snapshot.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let pendingConfirmation, pendingConfirmation.id == snapshot.id {
                    confirmation(pendingConfirmation, for: snapshot)
                }
            }

            Spacer(minLength: 0)

            if renamingID != snapshot.id, pendingConfirmation?.id != snapshot.id {
                rowActions(for: snapshot)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Revert to Snapshot") { pendingConfirmation = .init(id: snapshot.id, action: .revert) }
                .disabled(!snapshot.isUsable)
            Button("Rename") { beginRename(of: snapshot) }
            Divider()
            Button("Delete", role: .destructive) { pendingConfirmation = .init(id: snapshot.id, action: .delete) }
        }
    }

    private func rowActions(for snapshot: VBSnapshot) -> some View {
        HStack(spacing: 4) {
            Button {
                pendingConfirmation = .init(id: snapshot.id, action: .revert)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Revert to this snapshot")
            .disabled(!snapshot.isUsable)

            Menu {
                Button("Rename") { beginRename(of: snapshot) }
                Button("Delete", role: .destructive) { pendingConfirmation = .init(id: snapshot.id, action: .delete) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
    }

    // MARK: Confirming

    private func confirmation(_ pending: PendingConfirmation, for snapshot: VBSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(confirmationMessage(pending.action, for: snapshot))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { pendingConfirmation = nil }

                switch pending.action {
                case .revert:
                    Button("Revert") { revert(to: snapshot) }
                        .keyboardShortcut(.defaultAction)
                case .delete:
                    Button("Delete", role: .destructive) { delete(snapshot) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    private func confirmationMessage(_ action: PendingConfirmation.Action, for snapshot: VBSnapshot) -> String {
        switch action {
        case .revert:
            let consequence = controller.state.isActive || controller.state.isSaved
                ? "The virtual machine’s current state will be lost."
                : "Changes made to the disks since this snapshot will be lost."

            let outcome = snapshot.kind == .live
                ? "It resumes where the snapshot was taken."
                : "It stays shut down."

            return "\(consequence) \(outcome) Take a snapshot first to keep the current state."
        case .delete:
            return "This snapshot will be deleted. This can’t be undone."
        }
    }

    // MARK: Actions

    private func revert(to snapshot: VBSnapshot) {
        pendingConfirmation = nil
        perform { try await controller.revertToSnapshot(snapshot.id) }
    }

    private func delete(_ snapshot: VBSnapshot) {
        pendingConfirmation = nil
        perform { try await controller.deleteSnapshot(snapshot.id) }
    }

    private func beginRename(of snapshot: VBSnapshot) {
        pendingConfirmation = nil
        renameText = snapshot.name
        renamingID = snapshot.id
    }

    private func commitRename(of snapshot: VBSnapshot) {
        renamingID = nil

        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != snapshot.name else { return }

        perform { try await controller.renameSnapshot(snapshot.id, to: trimmed) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil

        Task { @MainActor in
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct SnapshotThumbnail: View {
    var snapshot: VBSnapshot

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)

            if let image = snapshot.screenshotURL.flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: snapshot.kind == .live ? "memorychip" : "internaldrive")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
