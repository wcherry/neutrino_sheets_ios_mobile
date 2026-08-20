import SwiftUI

// MARK: - TableStyleGalleryView

/// Epic 9 — "Table style gallery and table regions".
///
/// Eighty-five entries is too many to scroll blind, so the gallery is filtered by border treatment
/// rather than listing every combination at once: the three treatments differ in a way a thumbnail
/// barely shows, and picking the wrong one is a fourteen-swatch mistake to undo. Choosing the
/// treatment first cuts each page to twenty-eight.
struct TableStyleGalleryView: View {

    // MARK: - Input

    let onSelect: (TableStyle) -> Void

    // MARK: - State

    @Environment(\.dismiss) private var dismiss

    private enum BorderFilter: String, CaseIterable, Identifiable {
        case uniform = "Boxed"
        case horizontal = "Lines"
        case none = "None"

        var id: String { rawValue }

        /// The id suffix ``TableStyles`` generates for this treatment.
        var suffix: String {
            switch self {
            case .uniform:    return ""
            case .horizontal: return "-horizontal"
            case .none:       return "-no-border"
            }
        }
    }

    @State private var filter: BorderFilter = .uniform

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Borders", selection: $filter) {
                    ForEach(BorderFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(styles) { style in
                            Button {
                                onSelect(style)
                                dismiss()
                            } label: {
                                TableStyleSwatch(style: style)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(style.name)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Table Styles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// The filtered page, with Blank always first — it is how a table style is removed, and hunting
    /// for it at the end of a scroll would be the worst place to put the undo.
    private var styles: [TableStyle] {
        let blank = TableStyles.all.filter { $0.kind == .blank }
        let matching = TableStyles.all.filter { style in
            guard style.regular != nil else { return false }
            switch filter {
            case .uniform:    return !style.id.hasSuffix("-horizontal") && !style.id.hasSuffix("-no-border")
            case .horizontal: return style.id.hasSuffix("-horizontal")
            case .none:       return style.id.hasSuffix("-no-border")
            }
        }
        return blank + matching
    }
}

// MARK: - TableStyleSwatch

/// A four-row miniature of what a style does: header, two bands, and a total row when the layout
/// has one. Drawn from the style's own colours rather than from a picture, so it cannot fall out of
/// step with what applying it produces.
struct TableStyleSwatch: View {

    let style: TableStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(.separator), lineWidth: 1))

            Text(style.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let regular = style.regular {
            VStack(spacing: 0) {
                band(regular.headerBackground)
                band(regular.bandColorA)
                band(regular.bandColorB)
                band(regular.totalRow ? regular.headerBackground : regular.bandColorA)
            }
        } else {
            // Blank: an empty grid, which is what the entry leaves behind.
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: "slash.circle")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func band(_ hex: String) -> some View {
        (StyleColors.color(hex) ?? Color(.systemBackground))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
