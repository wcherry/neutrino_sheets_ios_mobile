import SwiftUI

// MARK: - AppTheme

/// Settings — "Theme".
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// What to hand SwiftUI's `.preferredColorScheme`. `nil` follows the device.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - AppSettings

/// The user's preferences, persisted in `UserDefaults`.
///
/// `@Published` rather than `@AppStorage` so that a single observable object can be injected into
/// the view tree and, more importantly, constructed against a throwaway `UserDefaults` suite in
/// tests — `@AppStorage` reads `.standard` unconditionally.
///
/// The Docs app's Markdown preferences (editor face, line numbers, smart lists, bracket closing,
/// indent width) are gone; a grid has no use for any of them. What replaces them is grid geometry.
@MainActor
final class AppSettings: ObservableObject {

    // MARK: - Keys

    enum Keys {
        static let theme            = "settings.theme"
        static let autoSaveInterval = "settings.autoSaveIntervalSeconds"
        static let defaultColumnWidth = "settings.defaultColumnWidth"
        static let defaultRowHeight   = "settings.defaultRowHeight"
        static let showGridLines      = "settings.showGridLines"
        static let showFormulaBar     = "settings.showFormulaBar"
        static let showFormatBar      = "settings.showFormatBar"
    }

    // MARK: - Allowed values

    /// Selectable auto-save intervals, in seconds. The web editor's own timer is 3 seconds
    /// (`usePersistence`), which is the default here too.
    static let autoSaveIntervalOptions: [TimeInterval] = [2, 3, 5, 10, 30]
    static let defaultAutoSaveInterval: TimeInterval = 3

    /// Grid geometry, in points. The defaults are the web app's `CELL_W` / `CELL_H` from
    /// `editor/constants.ts`, so a workbook with no stored widths lays out identically in both
    /// clients — a sheet whose columns are narrower on the phone would wrap text the web app does
    /// not wrap, and the two would disagree about what the file looks like.
    static let columnWidthRange: ClosedRange<Double> = 60...240
    static let defaultColumnWidth: Double = 100
    static let rowHeightRange: ClosedRange<Double> = 20...60
    static let defaultRowHeight: Double = 28

    // MARK: - Published settings

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// Epic 8 — "Autosave on an interval from Settings".
    @Published var autoSaveInterval: TimeInterval {
        didSet { defaults.set(autoSaveInterval, forKey: Keys.autoSaveInterval) }
    }

    /// The width used for a column the workbook has no `colWidths` entry for.
    @Published var defaultColumnWidth: Double {
        didSet {
            // Clamped on write rather than trusted from the caller: the value also arrives from
            // `UserDefaults`, where a stale build or a synced preference could have left anything,
            // and a zero-width column would divide by zero in the grid's virtualisation.
            let clamped = defaultColumnWidth.clamped(to: Self.columnWidthRange)
            if clamped != defaultColumnWidth {
                defaultColumnWidth = clamped
                return
            }
            defaults.set(defaultColumnWidth, forKey: Keys.defaultColumnWidth)
        }
    }

    /// The height used for a row the workbook has no `rowHeights` entry for.
    @Published var defaultRowHeight: Double {
        didSet {
            let clamped = defaultRowHeight.clamped(to: Self.rowHeightRange)
            if clamped != defaultRowHeight {
                defaultRowHeight = clamped
                return
            }
            defaults.set(defaultRowHeight, forKey: Keys.defaultRowHeight)
        }
    }

    @Published var showGridLines: Bool {
        didSet { defaults.set(showGridLines, forKey: Keys.showGridLines) }
    }

    /// Epic 8 — the formula bar above the grid. On by default; it is the only place a formula's
    /// source text is visible, since the cell itself shows the evaluated value.
    @Published var showFormulaBar: Bool {
        didSet { defaults.set(showFormulaBar, forKey: Keys.showFormulaBar) }
    }

    /// Epic 9 — the one-tap format bar under the grid. On by default, and switchable because it
    /// costs a row of screen on a phone that is already short of one; everything it offers is also
    /// in the Format sheet, so turning it off loses reach, not capability.
    @Published var showFormatBar: Bool {
        didSet { defaults.set(showFormatBar, forKey: Keys.showFormatBar) }
    }

    // MARK: - Private

    private let defaults: UserDefaults

    // MARK: - Init

    /// - Parameter defaults: injected in tests so a run cannot disturb the real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        let storedInterval = defaults.object(forKey: Keys.autoSaveInterval) as? Double
        self.autoSaveInterval = storedInterval ?? Self.defaultAutoSaveInterval
        let storedWidth = defaults.object(forKey: Keys.defaultColumnWidth) as? Double
        self.defaultColumnWidth = (storedWidth ?? Self.defaultColumnWidth)
            .clamped(to: Self.columnWidthRange)
        let storedHeight = defaults.object(forKey: Keys.defaultRowHeight) as? Double
        self.defaultRowHeight = (storedHeight ?? Self.defaultRowHeight)
            .clamped(to: Self.rowHeightRange)
        self.showGridLines = defaults.object(forKey: Keys.showGridLines) as? Bool ?? true
        self.showFormulaBar = defaults.object(forKey: Keys.showFormulaBar) as? Bool ?? true
        self.showFormatBar = defaults.object(forKey: Keys.showFormatBar) as? Bool ?? true
    }

    // MARK: - Derived

    /// The geometry the grid should lay out with.
    var gridMetrics: GridMetrics {
        GridMetrics(defaultColumnWidth: defaultColumnWidth,
                    defaultRowHeight: defaultRowHeight)
    }

    /// Label for an auto-save interval, e.g. "Every 3 seconds".
    static func autoSaveLabel(for seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return whole == 1 ? "Every second" : "Every \(whole) seconds"
    }

    // MARK: - Reset

    /// Restores every setting to its default. Used by Settings' "Reset to Defaults".
    func resetToDefaults() {
        theme = .system
        autoSaveInterval = Self.defaultAutoSaveInterval
        defaultColumnWidth = Self.defaultColumnWidth
        defaultRowHeight = Self.defaultRowHeight
        showGridLines = true
        showFormulaBar = true
        showFormatBar = true
    }
}

// MARK: - Comparable + clamped

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
