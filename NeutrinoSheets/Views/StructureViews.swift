import SwiftUI

// MARK: - GridIndex

/// A column number or tab index that a `.sheet(item:)` can carry.
///
/// `Int` cannot be used directly — `sheet(item:)` needs `Identifiable`, and conforming a standard
/// library type to it would be a conformance the whole target has to live with for the sake of one
/// presentation. Wrapping is one line and reads at the call site as what it is: the sheet is open
/// *about something*, and the something is never nil while it is up.
struct GridIndex: Identifiable, Equatable {
    let id: Int
}

// MARK: - FindReplaceView

/// Epic 10 — "Find & replace".
///
/// Presented at a medium detent rather than full screen, and with the grid left interactive
/// underneath where the OS allows it: the whole point of stepping through matches is watching the
/// selection move, and a dialog covering the sheet turns "3 of 12" into a number with nothing
/// behind it.
struct FindReplaceView: View {

    // MARK: - Input

    @ObservedObject var model: SheetEditorModel

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var query = ""
    @State private var replacement = ""
    @State private var options = FindReplace.Options()
    @State private var showsReplace = false
    /// Which match the navigation is on. Clamped on read, because a replace can shrink the list
    /// under it.
    @State private var index = 0
    @FocusState private var queryFocused: Bool

    // MARK: - Body

    var body: some View {
        // Read once per layout pass: every match walks the whole tab, and asking for it separately
        // from the counter, the two navigation buttons and the two replace buttons would walk it
        // five times per keystroke.
        let matches = self.matches

        return NavigationStack {
            Form {
                Section {
                    TextField("Find", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($queryFocused)
                        .submitLabel(.search)
                        .onSubmit { step(by: 1) }

                    if showsReplace {
                        TextField("Replace with", text: $replacement)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } footer: {
                    Text(label(for: matches))
                        .foregroundStyle(matches.isEmpty && !query.isEmpty ? .red : .secondary)
                }

                Section {
                    Toggle("Match case", isOn: $options.matchCase)
                    Toggle("Entire cell", isOn: $options.entireCell)
                }

                Section {
                    HStack {
                        Button {
                            step(by: -1)
                        } label: {
                            Label("Previous", systemImage: "chevron.up")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(matches.isEmpty)

                        Divider()

                        Button {
                            step(by: 1)
                        } label: {
                            Label("Next", systemImage: "chevron.down")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(matches.isEmpty)
                    }
                    .buttonStyle(.borderless)
                }

                if model.isEditable {
                    Section {
                        if showsReplace {
                            Button("Replace") { replaceCurrent() }
                                .disabled(matches.isEmpty)
                            Button("Replace All") { replaceAll() }
                                .disabled(matches.isEmpty)
                        } else {
                            Button("Replace\u{2026}") { showsReplace = true }
                        }
                    } footer: {
                        // Said before it happens rather than after: a user replacing across a
                        // spreadsheet they share should know the formulas go stale here and come
                        // back on the web, not discover it.
                        if showsReplace {
                            Text("Searches what was typed, so formulas match as text. A replaced "
                                 + "formula recalculates when the sheet is next opened on the web.")
                        }
                    }
                }
            }
            .navigationTitle(showsReplace ? "Find and Replace" : "Find")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { queryFocused = true }
            .onChange(of: query) { _ in restart() }
            .onChange(of: options) { _ in restart() }
        }
        .presentationDetents([.medium, .large])
        .modifier(BackgroundInteractionModifier())
    }

    // MARK: - Matches

    private var matches: [CellAddress] {
        model.matches(for: query, options: options)
    }

    private func label(for matches: [CellAddress]) -> String {
        guard !query.isEmpty else { return "" }
        guard !matches.isEmpty else { return "No matches" }
        return "\(min(index, matches.count - 1) + 1) of \(matches.count)"
    }

    // MARK: - Navigation

    /// Jumps to the first match whenever the search itself changes.
    private func restart() {
        index = 0
        guard let first = matches.first else { return }
        model.selection = SheetSelection(first)
    }

    /// Wraps around at both ends, which is what makes Return a way to walk a column of matches
    /// without ever having to look at the count.
    private func step(by offset: Int) {
        let matches = self.matches
        guard !matches.isEmpty else { return }
        index = ((min(index, matches.count - 1) + offset) % matches.count + matches.count)
            % matches.count
        model.selection = SheetSelection(matches[index])
    }

    // MARK: - Replacing

    private func replaceCurrent() {
        let matches = self.matches
        guard !matches.isEmpty else { return }
        let target = matches[min(index, matches.count - 1)]
        model.replace(at: target, query: query, with: replacement, options: options)
        model.saveIfNeeded()
        // The list has just changed under the cursor. Clamping rather than advancing keeps the next
        // tap on the *next* match, which is where a repeated Replace has to land.
        index = min(index, max(0, self.matches.count - 1))
    }

    private func replaceAll() {
        let count = model.replaceAll(query: query, with: replacement, options: options)
        model.saveIfNeeded()
        index = 0
        guard count > 0 else { return }
        dismiss()
    }
}

// MARK: - BackgroundInteractionModifier

/// Lets the grid underneath stay usable while the sheet is at its medium detent.
///
/// Its own modifier only because `presentationBackgroundInteraction` arrived in iOS 16.4 and this
/// app targets 16.0; the `if #available` has to live somewhere, and burying it in the middle of a
/// view body reads worse than this does.
private struct BackgroundInteractionModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackgroundInteraction(.enabled(upThrough: .medium))
        } else {
            content
        }
    }
}

// MARK: - ColumnFilterView

/// Epic 10 — "Per-column filters".
///
/// The web app's filter dialog: every distinct entry in the column with a checkbox, a search box
/// over the list itself, and blanks offered as `(Blanks)` because hiding the empty rows under a
/// table is the most common thing anyone filters for.
struct ColumnFilterView: View {

    // MARK: - Input

    /// 1-based.
    let column: Int
    let values: [String]
    let current: Set<String>?
    let apply: (Set<String>?) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var selected: Set<String> = []
    @State private var search = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button("Select All") { selected.formUnion(visibleValues) }
                        Spacer()
                        Button("Clear All") { selected.subtract(visibleValues) }
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                }

                Section {
                    if visibleValues.isEmpty {
                        Text("No values").foregroundStyle(.secondary)
                    }
                    ForEach(visibleValues, id: \.self) { value in
                        Button {
                            toggle(value)
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(value)
                                        ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selected.contains(value) ? Color.accentColor
                                                                              : .secondary)
                                Text(value.isEmpty ? "(Blanks)" : value)
                                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search values")
            .navigationTitle("Filter \(CellAddress.columnLetters(column))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        // Everything ticked is the same as no filter at all, and storing it as one
                        // would leave the column marked as filtered while hiding nothing.
                        apply(selected.count == values.count ? nil : selected)
                        dismiss()
                    }
                }
                if current != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear Filter", role: .destructive) {
                            apply(nil)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { selected = current ?? Set(values) }
        }
    }

    // MARK: - Filtering the list

    private var visibleValues: [String] {
        guard !search.isEmpty else { return values }
        return values.filter {
            ($0.isEmpty ? "(Blanks)" : $0).localizedCaseInsensitiveContains(search)
        }
    }

    private func toggle(_ value: String) {
        if selected.contains(value) {
            selected.remove(value)
        } else {
            selected.insert(value)
        }
    }
}

// MARK: - SheetTabRenameView

/// Epic 10 — renaming a tab. Its own sheet rather than an inline field: the tab bar is a scrolling
/// strip of small targets, and editing in place on a phone puts the keyboard over the thing being
/// typed into.
struct SheetTabRenameView: View {

    let currentName: String
    let rename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Sheet name", text: $name)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(commit)
            }
            .navigationTitle("Rename Sheet")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { name = currentName }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        rename(trimmed)
        dismiss()
    }
}

// MARK: - SheetTabColorView

/// Epic 10 — colouring a tab. The colour is written into the workbook, so it shows on the web too.
struct SheetTabColorView: View {

    let current: String?
    let choose: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    swatch(color: nil, label: "None")
                    ForEach(SheetTabColors.all, id: \.value) { option in
                        swatch(color: option.value, label: option.label)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Sheet Colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func swatch(color: String?, label: String) -> some View {
        Button {
            choose(color)
            dismiss()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(color.flatMap { StyleColors.color($0) } ?? Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    if color == nil {
                        Image(systemName: "slash.circle").foregroundStyle(.secondary)
                    }
                    if current?.lowercased() == color?.lowercased() {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                            .frame(width: 48, height: 48)
                    }
                }
                .frame(width: 48, height: 48)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(current?.lowercased() == color?.lowercased() ? [.isSelected] : [])
    }
}
