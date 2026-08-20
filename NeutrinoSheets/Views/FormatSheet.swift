import SwiftUI

// MARK: - FormatSheet

/// Epic 9 — everything the format bar cannot fit.
///
/// Presented over the grid rather than beside it, which is the trade a phone forces: the controls
/// that are applied repeatedly stay on the bar, and the ones chosen once per range — a font, a
/// border, a number format, a table style — live here where they can be laid out legibly.
///
/// The sheet reads the *active cell's* style, so it opens showing what that cell has and every
/// control applies to the whole selection. That asymmetry is the web app's, and it is the only one
/// available: a range whose cells disagree has no single font to show.
struct FormatSheet: View {

    // MARK: - Input

    let style: CellStyle?
    let isMerged: Bool
    /// What the selection covers, shown in the title so it is clear what a control will change.
    let selectionAddress: String
    let perform: (FormatCommand) -> Void

    // MARK: - State

    @Environment(\.dismiss) private var dismiss

    private enum ColorTarget: Identifiable {
        case text, fill
        var id: Int { self == .text ? 0 : 1 }
    }

    @State private var colorTarget: ColorTarget?
    /// The weight the per-side border buttons apply. Not a stored style — it is the "pen" the four
    /// side buttons draw with, and a picker that reset itself after every side would make putting a
    /// box round a range a four-step chore.
    @State private var borderWeight = "thin"
    @State private var showTableStyles = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                textSection
                alignmentSection
                borderSection
                numberSection
                tableSection
                clearSection
            }
            .navigationTitle("Format \(selectionAddress)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
            .sheet(isPresented: $showTableStyles) {
                TableStyleGalleryView { style in
                    perform(.tableStyle(style))
                    // Dismissing the whole stack: the banding is the point, and it is behind two
                    // sheets.
                    dismiss()
                }
            }
        }
    }

    // MARK: - Text

    private var textSection: some View {
        Section("Text") {
            Picker("Font", selection: fontFamilyBinding) {
                ForEach(FormatOptions.fontFamilies, id: \.label) { family in
                    Text(family.label).tag(family.value ?? "")
                }
            }

            Picker("Size", selection: fontSizeBinding) {
                ForEach(FormatOptions.fontSizes, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }

            HStack(spacing: 10) {
                styleToggle("bold", isOn: style?.isBold ?? false, label: "Bold") {
                    perform(.style(.bold(!(style?.isBold ?? false)), name: "Bold"))
                }
                styleToggle("italic", isOn: style?.isItalic ?? false, label: "Italic") {
                    perform(.style(.italic(!(style?.isItalic ?? false)), name: "Italic"))
                }
                styleToggle("strikethrough", isOn: style?.isStrikethrough ?? false,
                            label: "Strikethrough") {
                    perform(.style(.strikethrough(!(style?.isStrikethrough ?? false)),
                                   name: "Strikethrough"))
                }
            }

            colorRow("Text Colour", value: style?.color, fallback: .primary) { colorTarget = .text }
            colorRow("Fill Colour", value: style?.backgroundColor, fallback: .clear) { colorTarget = .fill }
        }
    }

    // MARK: - Alignment

    private var alignmentSection: some View {
        Section("Alignment") {
            optionRow("Horizontal", options: FormatOptions.horizontalAlignments,
                      current: style?.textAlign) {
                perform(.style(.textAlign($0), name: "Align"))
            }
            optionRow("Vertical", options: FormatOptions.verticalAlignments,
                      // The web app's toolbar shows Middle as active when nothing is set, because
                      // that is what its CSS does.
                      current: style?.verticalAlign ?? "middle") {
                perform(.style(.verticalAlign($0), name: "Vertical Align"))
            }
            optionRow("Wrapping", options: FormatOptions.wrapModes,
                      current: style?.wrapMode ?? "overflow") {
                perform(.style(.wrapMode($0), name: "Wrap"))
            }
        }
    }

    // MARK: - Borders

    private var borderSection: some View {
        Section {
            Picker("Weight", selection: $borderWeight) {
                ForEach(FormatOptions.borderWeights.compactMap(\.value), id: \.self) { weight in
                    Text(weight.capitalized).tag(weight)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                borderButton("All", symbol: "square") {
                    perform(.style(.allBorders(borderWeight), name: "Borders"))
                }
                ForEach(CellStyle.BorderSide.allCases, id: \.self) { side in
                    borderButton(sideLabel(side), symbol: sideSymbol(side)) {
                        perform(.style(.border(side, borderWeight), name: "Border"))
                    }
                }
            }

            Button(role: .destructive) {
                // The all-sides command writes `"none"` and clears the per-side keys, which is the
                // only way to be rid of a border a per-side value is holding on.
                perform(.style(.allBorders(nil), name: "Borders"))
            } label: {
                Label("No Borders", systemImage: "square.dashed")
            }
        } header: {
            Text("Borders")
        } footer: {
            Text("Pick a weight, then an edge. \u{201C}All\u{201D} replaces every side.")
        }
    }

    // MARK: - Numbers

    private var numberSection: some View {
        Section("Numbers") {
            NavigationLink {
                NumberFormatPicker(style: style, perform: perform)
            } label: {
                HStack {
                    Text("Format")
                    Spacer()
                    Text(numberFormatSummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Stepper("Decimal places: \(style?.decimalPlaces ?? 0)") {
                perform(.style(.decimalPlaces((style?.decimalPlaces ?? 0) + 1), name: "Decimals"))
            } onDecrement: {
                guard (style?.decimalPlaces ?? 0) > 0 else { return }
                perform(.style(.decimalPlaces((style?.decimalPlaces ?? 0) - 1), name: "Decimals"))
            }
        }
    }

    /// What the Format row reads. A custom pattern wins because it is what actually renders — see
    /// ``CellFormatter/display(_:style:)`` — and showing the preset underneath it would name a
    /// format the cell is not using.
    private var numberFormatSummary: String {
        if let custom = style?.customFormat, !custom.isEmpty { return custom }
        guard let format = style?.numberFormat else { return "Automatic" }
        return format.capitalized
    }

    // MARK: - Tables and clearing

    private var tableSection: some View {
        Section("Table") {
            Button {
                showTableStyles = true
            } label: {
                Label("Table Styles\u{2026}", systemImage: "tablecells")
            }

            Button {
                perform(.toggleMerge)
                dismiss()
            } label: {
                Label(isMerged ? "Unmerge Cells" : "Merge Cells",
                      systemImage: isMerged ? "arrow.left.and.line.vertical.and.arrow.right"
                                            : "arrow.right.and.line.vertical.and.arrow.left")
            }
        }
    }

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                perform(.clearFormatting)
                dismiss()
            } label: {
                Label("Clear Formatting", systemImage: "paintbrush")
            }
        } footer: {
            Text("Removes every style from the selection. The values stay.")
        }
    }

    // MARK: - Pieces

    private func styleToggle(_ symbol: String, isOn: Bool, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 32)
                .background(isOn ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func colorRow(_ title: String, value: String?, fallback: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                RoundedRectangle(cornerRadius: 5)
                    .fill(StyleColors.color(value) ?? fallback)
                    .frame(width: 28, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(.separator), lineWidth: 1))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func optionRow(_ title: String, options: [FormatOptions.Option], current: String?,
                           apply: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(options, id: \.value) { option in
                Button {
                    apply(option.value)
                } label: {
                    Image(systemName: option.symbol)
                        .frame(width: 40, height: 30)
                        .background(current == option.value
                                        ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(current == option.value ? [.isSelected] : [])
            }
        }
    }

    private func borderButton(_ label: String, symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) border")
    }

    private func sideLabel(_ side: CellStyle.BorderSide) -> String {
        switch side {
        case .top:    return "Top"
        case .right:  return "Right"
        case .bottom: return "Bottom"
        case .left:   return "Left"
        }
    }

    /// The inset-third symbols read as an edge of a cell, which is what these buttons draw.
    private func sideSymbol(_ side: CellStyle.BorderSide) -> String {
        switch side {
        case .top:    return "rectangle.topthird.inset.filled"
        case .right:  return "rectangle.trailingthird.inset.filled"
        case .bottom: return "rectangle.bottomthird.inset.filled"
        case .left:   return "rectangle.leadingthird.inset.filled"
        }
    }

    // MARK: - Bindings

    /// Empty string stands for "Default" so the picker has a tag for every row; it is written back
    /// as an absent `fontFamily`.
    private var fontFamilyBinding: Binding<String> {
        Binding(get: { style?.fontFamily ?? "" },
                set: { perform(.style(.fontFamily($0.isEmpty ? nil : $0), name: "Font")) })
    }

    private var fontSizeBinding: Binding<Int> {
        Binding(get: { style?.pointSize.map { Int($0) } ?? FormatOptions.defaultFontSize },
                set: { perform(.style(.fontSize($0), name: "Font Size")) })
    }
}

// MARK: - NumberFormatPicker

/// Epic 9 — "Number formats and the custom-format dialog", ported from `CustomFormatDialog.tsx`.
///
/// The dialog's rule is reproduced rather than reinvented: a typed pattern is looked up in the
/// preset table, and a match brings its `numberFormat` and `decimalPlaces` with it. That is what
/// makes a cell formatted here indistinguishable from one formatted in the browser, rather than
/// merely looking the same until something reads the preset keys.
struct NumberFormatPicker: View {

    let style: CellStyle?
    let perform: (FormatCommand) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: NumberFormats.Category
    @State private var pattern: String

    init(style: CellStyle?, perform: @escaping (FormatCommand) -> Void) {
        self.style = style
        self.perform = perform
        let initial = NumberFormats.Category.forNumberFormat(style?.numberFormat)
        _category = State(initialValue: initial)
        _pattern = State(initialValue: style?.customFormat
                         ?? NumberFormats.presets(for: initial).first?.customFormat ?? "")
    }

    var body: some View {
        Form {
            Section {
                Picker("Category", selection: $category) {
                    ForEach(NumberFormats.Category.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: category) { newValue in
                    // Switching tabs resets to the first preset, as the dialog does — the pattern
                    // left over from another category would preview as nonsense.
                    pattern = NumberFormats.presets(for: newValue).first?.customFormat ?? ""
                }
            }

            Section("Presets") {
                ForEach(NumberFormats.presets(for: category)) { preset in
                    Button {
                        pattern = preset.customFormat
                    } label: {
                        HStack {
                            Text(preset.label)
                                .foregroundStyle(pattern == preset.customFormat
                                                 ? Color.accentColor : Color.primary)
                            Spacer()
                            Text(preset.customFormat)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                TextField("e.g. #,##0.00 or mmm yyyy", text: $pattern)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Text("Preview").foregroundStyle(.secondary)
                    Spacer()
                    Text(NumberFormats.preview(pattern: pattern, category: category))
                        .fontWeight(.medium)
                }
            } header: {
                Text("Custom Pattern")
            } footer: {
                Text("Leaving this empty removes the custom pattern and uses the category's "
                     + "default formatting.")
            }

            Section {
                Button("Apply") {
                    perform(.style(NumberFormats.patch(forPattern: pattern, category: category),
                                   name: "Number Format"))
                    dismiss()
                }
                Button(role: .destructive) {
                    perform(.style(CellStylePatch(numberFormat: .clear, decimalPlaces: .clear,
                                                  customFormat: .clear),
                                   name: "Number Format"))
                    dismiss()
                } label: {
                    Text("Remove Formatting")
                }
            }
        }
        .navigationTitle("Number Format")
        .navigationBarTitleDisplayMode(.inline)
    }
}
