import SwiftUI
import UIKit

// MARK: - CellEntryCommit

/// How an entry ended, which decides where the selection goes next.
///
/// Committing and moving are one action in a spreadsheet: Return enters the value *and* steps down,
/// and that is what makes typing a column possible without touching the screen between cells.
enum CellEntryCommit: Equatable {
    case done
    case cancelled
    case move(columns: Int, rows: Int)

    static let down = CellEntryCommit.move(columns: 0, rows: 1)
    static let up = CellEntryCommit.move(columns: 0, rows: -1)
    static let left = CellEntryCommit.move(columns: -1, rows: 0)
    static let right = CellEntryCommit.move(columns: 1, rows: 0)
}

// MARK: - CellEntryField

/// The formula bar's text field.
///
/// UIKit rather than SwiftUI's `TextField` for two reasons, both about the accessory row above the
/// keyboard that Epic 8 asks for:
///
/// - **Insertion at the caret.** A `$` tapped on the accessory has to land where the cursor is.
///   SwiftUI exposes no caret position, so a SwiftUI field could only append — which is wrong the
///   moment anyone edits the middle of an entry.
/// - **The row belongs to the field.** An `inputAccessoryView` follows this field specifically,
///   rather than SwiftUI's keyboard toolbar, which belongs to whatever happens to be focused.
struct CellEntryField: UIViewRepresentable {

    @Binding var text: String
    @Binding var isFocused: Bool
    var onCommit: (CellEntryCommit) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: UIFont.labelFontSize, weight: .regular)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.placeholder = "Value"
        // Not `.decimalPad`: a spreadsheet entry is as often a label or a formula as it is a
        // number, and a keyboard with no letters on it would make those impossible to type.
        field.keyboardType = .numbersAndPunctuation
        field.inputAccessoryView = context.coordinator.makeAccessoryView()
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)),
                        for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.field = field
        // Assigning unconditionally would move the caret to the end on every SwiftUI update, so
        // typing in the middle of a value would jump to the end after each character.
        if field.text != text { field.text = text }

        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextFieldDelegate {

        var parent: CellEntryField
        weak var field: UITextField?

        init(parent: CellEntryField) {
            self.parent = parent
        }

        // MARK: Text

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onCommit(.down)
            return false
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            // The keyboard going away — dismissed with the interactive gesture, or by focus moving
            // elsewhere — has to commit rather than silently drop what was typed.
            guard parent.isFocused else { return }
            parent.onCommit(.done)
        }

        // MARK: Accessory row

        /// Epic 8 — "Numeric keyboard accessory row (`= ( ) : , $ %` and arrows)".
        ///
        /// The symbols are the ones a spreadsheet needs and a phone keyboard buries two layers
        /// down; the arrows commit and step, which is how a column gets typed.
        func makeAccessoryView() -> UIView {
            let container = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 46),
                                        inputViewStyle: .keyboard)
            container.autoresizingMask = .flexibleWidth

            let symbols = UIStackView(arrangedSubviews: Self.symbols.map { symbol in
                button(title: symbol, accessibilityLabel: Self.symbolNames[symbol] ?? symbol,
                       action: #selector(insertSymbol(_:)))
            })
            symbols.spacing = 6

            // The symbols scroll: seven of them plus four arrows do not fit across an iPhone SE,
            // and shrinking them below a fingertip would be worse than making them scroll.
            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.addSubview(symbols)
            symbols.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                symbols.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                symbols.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                symbols.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                symbols.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                symbols.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            ])

            let arrows = UIStackView(arrangedSubviews: [
                button(image: "arrow.left", accessibilityLabel: "Commit and move left",
                       action: #selector(moveLeft)),
                button(image: "arrow.up", accessibilityLabel: "Commit and move up",
                       action: #selector(moveUp)),
                button(image: "arrow.down", accessibilityLabel: "Commit and move down",
                       action: #selector(moveDown)),
                button(image: "arrow.right", accessibilityLabel: "Commit and move right",
                       action: #selector(moveRight)),
                button(image: "keyboard.chevron.compact.down", accessibilityLabel: "Done",
                       action: #selector(commit)),
            ])
            arrows.spacing = 4
            arrows.setContentHuggingPriority(.required, for: .horizontal)
            arrows.setContentCompressionResistancePriority(.required, for: .horizontal)

            let row = UIStackView(arrangedSubviews: [scroll, arrows])
            row.spacing = 8
            row.alignment = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: container.layoutMarginsGuide.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: container.layoutMarginsGuide.trailingAnchor),
                row.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
                row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            ])
            return container
        }

        private static let symbols = ["=", "(", ")", ":", ",", "$", "%"]
        private static let symbolNames = [
            "=": "Equals", "(": "Open bracket", ")": "Close bracket", ":": "Range",
            ",": "Comma", "$": "Absolute reference", "%": "Percent",
        ]

        private func button(title: String? = nil, image: String? = nil, accessibilityLabel: String,
                            action: Selector) -> UIButton {
            var configuration = UIButton.Configuration.gray()
            configuration.title = title
            if let image { configuration.image = UIImage(systemName: image) }
            configuration.cornerStyle = .medium
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12,
                                                                  bottom: 4, trailing: 12)
            let button = UIButton(configuration: configuration)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
            button.accessibilityLabel = accessibilityLabel
            button.addTarget(self, action: action, for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            return button
        }

        @objc private func insertSymbol(_ sender: UIButton) {
            guard let symbol = sender.configuration?.title else { return }
            // `insertText` rather than appending: it respects the caret and any selected text,
            // which is the whole reason this field is UIKit.
            field?.insertText(symbol)
            parent.text = field?.text ?? ""
        }

        @objc private func moveLeft() { parent.onCommit(.left) }
        @objc private func moveUp() { parent.onCommit(.up) }
        @objc private func moveDown() { parent.onCommit(.down) }
        @objc private func moveRight() { parent.onCommit(.right) }
        @objc private func commit() { parent.onCommit(.done) }
    }
}
