import SwiftUI

// MARK: - CreateSpreadsheetSheet

/// Epic 4 — "Create a spreadsheet with `POST /api/v1/drive/files`".
struct CreateSpreadsheetSheet: View {

    let parentID: String?

    @EnvironmentObject private var driveService: SheetsDriveService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Spreadsheet name", text: $name)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(create)
                } footer: {
                    Text("Created in Neutrino Drive and encrypted on this device. Opens on the web too.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Spreadsheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                _ = try await driveService.createSpreadsheet(name: trimmed, parentID: parentID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - CreateFolderSheet

struct CreateFolderSheet: View {

    let parentID: String?

    @EnvironmentObject private var driveService: SheetsDriveService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $name)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(create)
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        driveService.createFolder(name: trimmed, parentID: parentID)
        dismiss()
    }
}

// MARK: - RenameSheet

/// Epic 4 — "Rename (`PATCH /drive/files/{id}`)".
struct RenameSheet: View {

    let item: SheetItem

    @EnvironmentObject private var driveService: SheetsDriveService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(rename)
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { name = item.name }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: rename)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else {
            dismiss()
            return
        }
        driveService.rename(itemID: item.id, to: trimmed)
        dismiss()
    }
}

// MARK: - MoveSheet

/// Epic 4 — "Move".
///
/// Only folders the item can legally land in are offered: its own subtree is excluded, since moving
/// a folder inside itself would detach it from the drive entirely.
struct MoveSheet: View {

    let item: SheetItem

    @EnvironmentObject private var driveService: SheetsDriveService
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(id: nil, name: "Drive", icon: "externaldrive", indent: 0)
                    ForEach(destinations, id: \.item.id) { destination in
                        row(id: destination.item.id,
                            name: destination.item.name,
                            icon: "folder",
                            indent: destination.depth + 1)
                    }
                } header: {
                    Text("Move \u{201C}\(item.displayName)\u{201D} to")
                }
            }
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { selection = item.parentID }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        driveService.move(itemID: item.id, to: selection)
                        dismiss()
                    }
                    .disabled(selection == item.parentID)
                }
            }
        }
    }

    private func row(id: String?, name: String, icon: String, indent: Int) -> some View {
        Button {
            selection = id
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                if selection == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.leading, CGFloat(indent) * 16)
        }
    }

    /// The folder tree, depth-first, minus the item itself and anything beneath it.
    private var destinations: [(item: SheetItem, depth: Int)] {
        var result: [(SheetItem, Int)] = []

        func walk(parentID: String?, depth: Int) {
            let folders = driveService.allItems
                .filter { $0.type == .folder && $0.parentID == parentID && !$0.isTrashed }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for folder in folders {
                guard folder.id != item.id else { continue }
                guard !driveService.isDescendant(potentialChildID: folder.id, ofFolderID: item.id) else {
                    continue
                }
                result.append((folder, depth))
                walk(parentID: folder.id, depth: depth + 1)
            }
        }

        walk(parentID: nil, depth: 0)
        return result
    }
}
