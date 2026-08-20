import SwiftUI

// MARK: - FormatCommand

/// Epic 9 — a formatting request raised by the format bar or the format sheet.
///
/// The same shape as ``GridCommand`` and for the same reason: the controls do not own the workbook,
/// and routing every one of them through a single method in ``SheetEditorView`` is what makes sure
/// a half-typed cell entry is committed before any of them reads the cells.
enum FormatCommand {
    /// A style patch applied across the selection, with the name its undo entry will carry.
    case style(CellStylePatch, name: String)
    case toggleMerge
    case clearFormatting
    case tableStyle(TableStyle)
}

// MARK: - FormatBar

/// The one-tap formatting row under the grid.
///
/// A phone cannot show the web app's toolbar — it is thirty controls wide — so this carries only
/// the commands worth a single tap, and everything else lives in ``FormatSheet`` behind the last
/// button. What earns a place here is the same test the web toolbar's leftmost groups pass: it is
/// applied repeatedly while looking at the grid, and a sheet covering the grid would defeat it.
///
/// Scrolls horizontally rather than wrapping, because a bar that changes height as the selection
/// changes would move the grid under the user's finger.
struct FormatBar: View {

    // MARK: - Input

    /// The active cell's style, which is what the toggles show as current.
    let style: CellStyle?
    let isMerged: Bool
    let perform: (FormatCommand) -> Void
    let onMore: () -> Void

    // MARK: - State

    private enum ColorTarget: Identifiable {
        case text, fill
        var id: Int { self == .text ? 0 : 1 }
    }

    @State private var colorTarget: ColorTarget?

    // MARK: - Body

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                textStyleGroup
                separator
                colorGroup
                separator
                alignmentGroup
                separator
                wrapAndMergeGroup
                separator
                numberGroup
                separator
                moreButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(Color(.secondarySystemBackground))
        .sheet(item: $colorTarget) { target in
            switch target {
            case .text:
                ColorPickerSheet(title: "Text Colour", selected: style?.color,
                                 clearLabel: "Automatic") {
                    perform(.style(.textColor($0), name: "Text Colour"))
                }
            case .fill:
                ColorPickerSheet(title: "Fill Colour", selected: style?.backgroundColor,
                                 clearLabel: "No Fill") {
                    perform(.style(.fillColor($0), name: "Fill Colour"))
                }
            }
        }
    }

    // MARK: - Groups

    private var textStyleGroup: some View {
        Group {
            button("bold", isOn: style?.isBold ?? false, label: "Bold") {
                perform(.style(.bold(!(style?.isBold ?? false)), name: "Bold"))
            }
            button("italic", isOn: style?.isItalic ?? false, label: "Italic") {
                perform(.style(.italic(!(style?.isItalic ?? false)), name: "Italic"))
            }
            button("strikethrough", isOn: style?.isStrikethrough ?? false, label: "Strikethrough") {
                perform(.style(.strikethrough(!(style?.isStrikethrough ?? false)),
                               name: "Strikethrough"))
            }
        }
    }

    /// Both colour buttons carry a bar of the colour they would apply, which is the only way to see
    /// what a cell's fill is without selecting it and reading a menu.
    private var colorGroup: some View {
        Group {
            Button {
                colorTarget = .text
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "character")
                    colorRule(StyleColors.color(style?.color) ?? .primary)
                }
                .frame(minWidth: 38, minHeight: 34)
            }
            .accessibilityLabel("Text colour")

            Button {
                colorTarget = .fill
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "paintbrush.fill")
                    colorRule(StyleColors.color(style?.backgroundColor) ?? .clear)
                }
                .frame(minWidth: 38, minHeight: 34)
            }
            .accessibilityLabel("Fill colour")
        }
    }

    private func colorRule(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: 18, height: 3)
            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color(.separator), lineWidth: 0.5))
    }

    private var alignmentGroup: some View {
        Group {
            ForEach(FormatOptions.horizontalAlignments, id: \.value) { option in
                button(option.symbol, isOn: style?.textAlign == option.value, label: option.label) {
                    perform(.style(.textAlign(option.value), name: "Align"))
                }
            }
        }
    }

    private var wrapAndMergeGroup: some View {
        Group {
            Menu {
                Picker("Wrap", selection: wrapBinding) {
                    ForEach(FormatOptions.wrapModes, id: \.value) { option in
                        Label(option.label, systemImage: option.symbol).tag(option.value)
                    }
                }
            } label: {
                Image(systemName: FormatOptions.wrapSymbol(for: style?.wrapMode))
                    .frame(minWidth: 38, minHeight: 34)
            }
            .accessibilityLabel("Text wrapping")

            // One button for both directions, like the web app's: a selection is either sitting on
            // a merge, in which case splitting it is the only thing left to do, or it is not.
            button(isMerged ? "arrow.left.and.line.vertical.and.arrow.right"
                            : "arrow.right.and.line.vertical.and.arrow.left",
                   isOn: isMerged, label: isMerged ? "Unmerge cells" : "Merge cells") {
                perform(.toggleMerge)
            }
        }
    }

    private var numberGroup: some View {
        Group {
            ForEach(NumberFormats.quickFormats, id: \.id) { format in
                let isOn = style?.numberFormat == format.id
                Button {
                    // Tapping the format a cell already has takes it off, which is how the web
                    // app's toggle buttons behave.
                    perform(.style(.numberFormat(isOn ? nil : format.id), name: format.accessibilityLabel))
                } label: {
                    Text(format.label)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 38, minHeight: 34)
                        .background(isOn ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .accessibilityLabel(format.accessibilityLabel)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }

            decimalButton("\u{2212}.0", label: "Decrease decimal places",
                          disabled: (style?.decimalPlaces ?? 0) <= 0) {
                perform(.style(.decimalPlaces((style?.decimalPlaces ?? 0) - 1), name: "Decimals"))
            }
            decimalButton("+.0", label: "Increase decimal places", disabled: false) {
                perform(.style(.decimalPlaces((style?.decimalPlaces ?? 0) + 1), name: "Decimals"))
            }
        }
    }

    private var moreButton: some View {
        Button(action: onMore) {
            HStack(spacing: 5) {
                Image(systemName: "textformat")
                Text("Format").font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityLabel("More formatting")
    }

    // MARK: - Pieces

    private var separator: some View {
        Divider().frame(height: 22).padding(.horizontal, 4)
    }

    private func button(_ symbol: String, isOn: Bool, label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(minWidth: 38, minHeight: 34)
                .background(isOn ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func decimalButton(_ text: String, label: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(minWidth: 38, minHeight: 34)
        }
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    /// Reads the current wrap mode and writes the chosen one. The menu's `Picker` needs a binding,
    /// and the workbook is not one.
    private var wrapBinding: Binding<String> {
        Binding(get: { style?.wrapMode ?? "overflow" },
                set: { perform(.style(.wrapMode($0), name: "Wrap")) })
    }
}

// MARK: - FormatOptions

/// The option lists the format bar and the format sheet both draw, kept in one place so the two
/// cannot offer different sets of alignments.
enum FormatOptions {

    struct Option {
        let value: String
        let label: String
        let symbol: String
    }

    static let horizontalAlignments = [
        Option(value: "left", label: "Align left", symbol: "text.alignleft"),
        Option(value: "center", label: "Align centre", symbol: "text.aligncenter"),
        Option(value: "right", label: "Align right", symbol: "text.alignright"),
    ]

    static let verticalAlignments = [
        Option(value: "top", label: "Align top", symbol: "arrow.up.to.line"),
        Option(value: "middle", label: "Align middle", symbol: "arrow.up.and.down"),
        Option(value: "bottom", label: "Align bottom", symbol: "arrow.down.to.line"),
    ]

    static let wrapModes = [
        Option(value: "overflow", label: "Overflow", symbol: "arrow.right.to.line"),
        Option(value: "wrap", label: "Wrap", symbol: "arrow.turn.down.left"),
        Option(value: "clip", label: "Clip", symbol: "scissors"),
    ]

    /// Border weights, in the order the web app's dropdown lists them. `nil` is "no border", which
    /// is stored as `"none"` rather than as an absent key — see ``CellStylePatch/allBorders(_:)``.
    static let borderWeights: [(value: String?, label: String)] = [
        (nil, "None"), ("thin", "Thin"), ("medium", "Medium"), ("thick", "Thick"),
    ]

    /// The font sizes the web app's dropdown offers, so a size set here is one its toolbar can show.
    static let fontSizes = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72]

    /// The default size the web editor renders an unstyled cell at, which is what its size
    /// dropdown shows when a cell has none.
    static let defaultFontSize = 11

    /// The font stacks the web app's family dropdown writes. The *values* are CSS stacks and are
    /// stored verbatim; ``GridStyleResolver/font(for:defaultSize:)`` resolves them to whatever the
    /// device actually has, falling back to the system face.
    static let fontFamilies: [(label: String, value: String?)] = [
        ("Default", nil),
        ("Arial", "Arial, sans-serif"),
        ("Georgia", "Georgia, serif"),
        ("Times New Roman", "'Times New Roman', serif"),
        ("Courier New", "'Courier New', monospace"),
        ("Verdana", "Verdana, sans-serif"),
        ("Trebuchet MS", "'Trebuchet MS', sans-serif"),
        ("Roboto", "'Roboto', sans-serif"),
        ("Open Sans", "'Open Sans', sans-serif"),
        ("Lato", "'Lato', sans-serif"),
        ("Playfair Display", "'Playfair Display', serif"),
        ("Impact", "Impact, sans-serif"),
        ("Comic Sans MS", "'Comic Sans MS', cursive"),
    ]

    static func wrapSymbol(for mode: String?) -> String {
        wrapModes.first { $0.value == mode }?.symbol ?? "arrow.right.to.line"
    }
}
