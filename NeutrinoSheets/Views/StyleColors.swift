import SwiftUI
import UIKit

// MARK: - StyleColors

/// The colours the format controls offer, and the conversion between a SwiftUI `Color` and the CSS
/// string a workbook stores.
///
/// Everything written into a workbook is `#rrggbb`. The web app's own picker writes hex, the grid
/// renderer parses it (``GridStyleResolver/color(_:)``), and a device-dependent spelling — a
/// `UIColor` description, a P3 `color()` function — would be a value the browser could not read at
/// all. Alpha is dropped for the same reason the web app's picker has no alpha slider: a
/// half-transparent cell fill has no meaning in a format whose renderer composites nothing.
///
/// Main-actor isolated because ``GridStyleResolver`` is: its parse cache is unsynchronised shared
/// state, deliberately, since every caller is a render or a control on the main thread.
@MainActor
enum StyleColors {

    // MARK: - Palette

    /// Neutrals, saturated hues and their tints — the same three-tier shape a spreadsheet colour
    /// menu has, and drawn from the palette the table styles already use so a hand-picked fill
    /// matches a banded table.
    static let palette: [[String]] = [
        ["#000000", "#374151", "#6b7280", "#9ca3af", "#d1d5db", "#e5e7eb", "#f3f4f6", "#ffffff"],
        ["#b91c1c", "#c2410c", "#b45309", "#15803d", "#0f766e", "#1e40af", "#4338ca", "#6d28d9"],
        ["#fee2e2", "#ffedd5", "#fef3c7", "#dcfce7", "#ccfbf1", "#dbeafe", "#e0e7ff", "#ede9fe"],
    ]

    // MARK: - Conversion

    /// A stored CSS colour as a SwiftUI colour, or nil when it is absent or unreadable.
    ///
    /// Routed through ``GridStyleResolver`` rather than parsed again here so the swatch a control
    /// shows and the fill the grid draws can never disagree about what `"rgb(30 64 175)"` means.
    static func color(_ css: String?) -> Color? {
        GridStyleResolver.color(css).map(Color.init)
    }

    /// `#rrggbb`, lowercase, in sRGB.
    ///
    /// `UIColor` is asked for its components in the extended sRGB space and the result clamped:
    /// a colour picked in Display P3 can hand back components outside 0…1, which would otherwise
    /// format as `#ff-3ff` — a string nothing can parse.
    static func hex(from color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let channel = { (value: CGFloat) in Int((value.clamped(to: 0...1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", channel(red), channel(green), channel(blue))
    }
}

// MARK: - ColorPickerSheet

/// Picks one colour for a style field: a swatch grid, an arbitrary-colour picker, and a way back to
/// no colour at all.
///
/// "Automatic" is not the same as white. A cell with no `color` inherits the grid's text colour and
/// follows Dark Mode with it; a cell explicitly set to `#000000` stays black on a dark background,
/// where it is unreadable. Offering the two as separate choices is what keeps a user from picking
/// the second when they meant the first.
struct ColorPickerSheet: View {

    // MARK: - Input

    let title: String
    /// What the field currently holds, so the grid can mark it.
    let selected: String?
    /// The wording for clearing the field — "Automatic" for text, "No Fill" for a background.
    let clearLabel: String
    let onPick: (String?) -> Void

    // MARK: - State

    @Environment(\.dismiss) private var dismiss
    @State private var custom: Color = .accentColor

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(StyleColors.palette.enumerated()), id: \.offset) { _, row in
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(row, id: \.self) { hex in
                                swatch(hex)
                            }
                        }
                    }

                    Divider()

                    ColorPicker("Custom Colour", selection: $custom, supportsOpacity: false)
                        .onChange(of: custom) { pick(StyleColors.hex(from: $0)) }

                    Button(role: .destructive) {
                        pick(nil)
                    } label: {
                        Label(clearLabel, systemImage: "slash.circle")
                    }
                }
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Pieces

    private func swatch(_ hex: String) -> some View {
        let isSelected = selected?.lowercased() == hex
        return Button {
            pick(hex)
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(StyleColors.color(hex) ?? .clear)
                .frame(height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color(.separator),
                                      lineWidth: isSelected ? 3 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Applies and dismisses in one step: a colour sheet that stays open after a tap makes the user
    /// close it themselves to see what they picked, over the grid it just changed.
    private func pick(_ hex: String?) {
        onPick(hex)
        dismiss()
    }
}
