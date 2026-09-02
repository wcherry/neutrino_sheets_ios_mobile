import Foundation

// MARK: - SheetTabs

/// Epic 10 — "Add / rename / colour / reorder / duplicate / delete sheet tabs".
///
/// Pure operations on a workbook's tab list, ported from the web app's `useSheets`. They are here
/// rather than in the editor model because every one of them is a rearrangement of an array that
/// wants testing on its own, and because the active-tab bookkeeping — which tab you end up looking
/// at after deleting the one you were on — is the part that is easy to get wrong.
enum SheetTabs {

    // MARK: - Result

    /// A tab list and which tab should be showing afterwards.
    struct Outcome: Equatable {
        var sheets: [SheetData]
        var activeIndex: Int
    }

    // MARK: - Naming

    /// The first unused `Sheet N`.
    ///
    /// The web app writes `Sheet ${count + 1}`, which repeats a name as soon as a tab has been
    /// deleted — delete Sheet 2 of three and the next tab added is a second "Sheet 3". Names are
    /// what cross-sheet formulas will refer to in Epic 15, so two tabs sharing one is worth not
    /// creating.
    static func nextName(after sheets: [SheetData]) -> String {
        let taken = Set(sheets.compactMap(\.name))
        var number = sheets.count + 1
        while taken.contains("Sheet \(number)") { number += 1 }
        return "Sheet \(number)"
    }

    /// The name a copy gets — the web app's `${name} (copy)`.
    static func copyName(of sheet: SheetData, at index: Int, in sheets: [SheetData]) -> String {
        let base = sheet.name ?? "Sheet \(index + 1)"
        let taken = Set(sheets.compactMap(\.name))
        let first = "\(base) (copy)"
        guard taken.contains(first) else { return first }
        var number = 2
        while taken.contains("\(first) \(number)") { number += 1 }
        return "\(first) \(number)"
    }

    // MARK: - Operations

    /// Adds an empty tab at the end and moves to it.
    static func add(to sheets: [SheetData]) -> Outcome {
        var result = sheets
        result.append(SheetData(name: nextName(after: sheets)))
        return Outcome(sheets: result, activeIndex: result.count - 1)
    }

    /// Renames a tab. A blank name is refused rather than stored — the web app falls back to the old
    /// name for the same reason, and an unnamed tab is one the formula engine cannot address.
    static func rename(_ sheets: [SheetData], at index: Int, to name: String) -> [SheetData] {
        guard sheets.indices.contains(index) else { return sheets }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sheets }
        var result = sheets
        result[index].name = trimmed
        return result
    }

    /// Sets or clears a tab's colour. Nil is "no colour", written as an absent key.
    static func setColor(_ sheets: [SheetData], at index: Int, to color: String?) -> [SheetData] {
        guard sheets.indices.contains(index) else { return sheets }
        var result = sheets
        result[index].color = color
        return result
    }

    /// Copies a tab, placing the copy **directly after** the original.
    ///
    /// The web app appends it to the end instead. Diverging is a phone decision: the tab bar
    /// scrolls, and on a workbook with eight tabs a copy that lands off the right-hand edge is one
    /// the user has to go looking for. The array order is what both clients read, so the copy is in
    /// the same place whichever client opens it next.
    static func duplicate(_ sheets: [SheetData], at index: Int) -> Outcome {
        guard sheets.indices.contains(index) else {
            return Outcome(sheets: sheets, activeIndex: index)
        }
        var copy = sheets[index]
        copy.name = copyName(of: sheets[index], at: index, in: sheets)
        var result = sheets
        result.insert(copy, at: index + 1)
        return Outcome(sheets: result, activeIndex: index + 1)
    }

    /// Removes a tab, unless it is the last one — a workbook with no tabs is not a workbook, and the
    /// web app refuses this too.
    static func delete(_ sheets: [SheetData], at index: Int, activeIndex: Int) -> Outcome? {
        guard sheets.count > 1, sheets.indices.contains(index) else { return nil }
        var result = sheets
        result.remove(at: index)

        // Deleting the tab you are on lands you on the one to its left, which is where the eye
        // already is. Deleting one before it keeps you where you are, renumbered.
        var newActive = activeIndex
        if activeIndex == index {
            newActive = max(0, index - 1)
        } else if activeIndex > index {
            newActive = activeIndex - 1
        }
        return Outcome(sheets: result, activeIndex: min(newActive, result.count - 1))
    }

    /// Moves a tab one place left or right, carrying the active selection with it.
    static func move(_ sheets: [SheetData], from index: Int, by offset: Int,
                     activeIndex: Int) -> Outcome? {
        let target = index + offset
        guard sheets.indices.contains(index), sheets.indices.contains(target), offset != 0 else {
            return nil
        }
        var result = sheets
        result.swapAt(index, target)

        var newActive = activeIndex
        if activeIndex == index {
            newActive = target
        } else if activeIndex == target {
            newActive = index
        }
        return Outcome(sheets: result, activeIndex: newActive)
    }
}

// MARK: - Tab colours

/// The colours offered for a tab.
///
/// Stored as `#rrggbb`, the same spelling every other colour in the format uses, so a tab coloured
/// here shows the same colour in the browser. The set is the web app's swatch palette; "None" is
/// offered separately because a tab with no colour follows the theme and one explicitly set to grey
/// does not.
enum SheetTabColors {

    static let all: [(label: String, value: String)] = [
        ("Red", "#ef4444"),
        ("Orange", "#f97316"),
        ("Amber", "#f59e0b"),
        ("Green", "#22c55e"),
        ("Teal", "#14b8a6"),
        ("Blue", "#3b82f6"),
        ("Indigo", "#6366f1"),
        ("Purple", "#a855f7"),
        ("Pink", "#ec4899"),
        ("Slate", "#64748b"),
    ]
}
