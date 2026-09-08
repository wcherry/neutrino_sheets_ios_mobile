import SwiftUI
import NeutrinoCore

// MARK: - SheetBrowserView

/// Epic 4 — Drive Integration: browsing, and the operations on a spreadsheet.
///
/// One view serves every section. Home navigates into folders; Recent, Favorites, Shared and Trash
/// are flat listings (see ``SheetsSection/supportsFolderNavigation``).
struct SheetBrowserView: View {

    // MARK: - Input

    let section: SheetsSection
    /// The folder being listed. Always nil outside Home.
    var parentID: String? = nil
    var title: String? = nil

    // MARK: - Environment

    @EnvironmentObject private var driveService: SheetsDriveService
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    // MARK: - State

    @State private var showCreateSpreadsheet = false
    @State private var showCreateFolder = false
    @State private var renameTarget: SheetItem?
    @State private var moveTarget: SheetItem?
    @State private var isWorking = false
    @State private var actionError: String?

    // MARK: - Body

    var body: some View {
        List {
            if items.isEmpty && !driveService.isLoading {
                EmptySectionView(section: section)
                    .listRowSeparator(.hidden)
            }

            ForEach(items) { item in
                row(for: item)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title ?? section.rawValue)
        .navigationBarTitleDisplayMode(parentID == nil ? .large : .inline)
        .toolbar { toolbarContent }
        .refreshable { await driveService.load(section, parentID: parentID) }
        .task { await driveService.load(section, parentID: parentID) }
        .overlay {
            if driveService.isLoading && items.isEmpty {
                ProgressView()
            }
        }
        .sheet(isPresented: $showCreateSpreadsheet) {
            CreateSpreadsheetSheet(parentID: parentID)
        }
        .sheet(isPresented: $showCreateFolder) {
            CreateFolderSheet(parentID: parentID)
        }
        .sheet(item: $renameTarget) { item in
            RenameSheet(item: item)
        }
        .sheet(item: $moveTarget) { item in
            MoveSheet(item: item)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: SheetItem) -> some View {
        if item.type == .folder && section.supportsFolderNavigation {
            NavigationLink {
                SheetBrowserView(section: section, parentID: item.id, title: item.name)
            } label: {
                SheetRowView(item: item)
            }
            .contextMenu { contextMenu(for: item) }
        } else if item.type == .file && section != .trash {
            NavigationLink {
                SheetEditorView(item: item)
            } label: {
                SheetRowView(item: item)
            }
            .contextMenu { contextMenu(for: item) }
            .swipeActions(edge: .trailing) {
                if !item.isShared {
                    Button(role: .destructive) {
                        driveService.delete(itemID: item.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } else {
            SheetRowView(item: item)
                .contextMenu { contextMenu(for: item) }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: SheetItem) -> some View {
        if section == .trash {
            Button {
                driveService.restore(itemID: item.id)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                driveService.delete(itemID: item.id)
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        } else {
            // Drive scopes rename, move, star and trash to the owner; offering them on somebody
            // else's spreadsheet would only produce a 403.
            if !item.isShared {
                Button {
                    driveService.setStarred(itemID: item.id, isStarred: !item.isStarred)
                } label: {
                    Label(item.isStarred ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: item.isStarred ? "star.slash" : "star")
                }

                Button {
                    renameTarget = item
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    moveTarget = item
                } label: {
                    Label("Move…", systemImage: "folder")
                }
            }

            // Duplicating goes through this app's codec, so it is offered for a spreadsheet and not
            // for whatever else a shared listing may hold.
            if item.isNativeSheet {
                Button {
                    duplicate(item)
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                .disabled(!networkMonitor.isOnline)
            }

            if !item.isShared {
                Divider()
                Button(role: .destructive) {
                    driveService.delete(itemID: item.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if section == .trash {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Empty", role: .destructive) {
                    driveService.emptyTrash()
                }
                .disabled(driveService.trashItems.isEmpty)
            }
        } else if section == .home && FeatureFlags.driveIntegration {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showCreateSpreadsheet = true
                    } label: {
                        Label("New Spreadsheet", systemImage: "tablecells.badge.ellipsis")
                    }
                    .disabled(!networkMonitor.isOnline)

                    Button {
                        showCreateFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(!networkMonitor.isOnline)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create")
            }
        }
    }

    // MARK: - Data

    private var items: [SheetItem] {
        // Folders before spreadsheets, then by name — the ordering people expect from a file
        // browser, except in Recent, where the server's newest-first order is the point.
        let raw = driveService.items(in: section, parentID: parentID)
        guard section != .recent else { return raw }
        return raw.sorted { lhs, rhs in
            if lhs.type != rhs.type { return lhs.type == .folder }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Actions

    private func duplicate(_ item: SheetItem) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await driveService.duplicate(itemID: item.id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

// MARK: - EmptySectionView

/// Epic 1 — "Empty states".
struct EmptySectionView: View {
    let section: SheetsSection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: section.emptyIcon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(section.emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
    }
}

// MARK: - SheetRowView

/// One row in a listing.
struct SheetRowView: View {
    let item: SheetItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .foregroundStyle(item.type == .folder ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if item.isStarred {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
            if item.isShared {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Shared with you")
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [Self.dateFormatter.localizedString(for: item.modifiedAt, relativeTo: Date())]
        if let size = item.size, item.type == .file {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
