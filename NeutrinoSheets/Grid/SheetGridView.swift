import SwiftUI
import UIKit

// MARK: - GridCommand

/// A clipboard or history command raised by the grid — from the edit menu, a key command, or a
/// hardware keyboard shortcut. The grid does not own the workbook, so it asks rather than acts.
enum GridCommand {
    case cut, copy, paste, clear, undo, redo
}

// MARK: - StructureCommand

/// Epic 10 — a structural request raised from a row or column header.
///
/// Separate from ``GridCommand`` because these are the commands a header owns, and because two of
/// them (`filter`, `clearFilter`) are not edits at all — they change how the workbook is *looked
/// at*. Routing them all through one callback keeps the header menu, the actions menu and any
/// future keyboard shortcut hitting the same code.
enum StructureCommand: Equatable {
    /// Insert as many rows as the selection covers, above it or below it.
    case insertRows(before: Bool)
    case insertColumns(before: Bool)
    case deleteRows
    case deleteColumns
    case hideRows
    case hideColumns
    /// Put back whatever is hidden inside the selection.
    case show
    /// Sort by one column. Which rows move depends on the selection — see
    /// ``SheetEditorModel/sort(by:ascending:)``.
    case sort(column: Int, ascending: Bool)
    /// Open the filter list for a column. Presented in SwiftUI, so the grid only asks.
    case filter(column: Int)
    case clearFilter(column: Int)
    /// A resize drag that has finished. `size` is in points at the current zoom.
    case resizeColumns(ClosedRange<Int>, Double)
    case resizeRows(ClosedRange<Int>, Double)
    case freezeToSelection
    case unfreeze
}

// MARK: - SheetGridView

/// The spreadsheet grid, hosted in SwiftUI.
///
/// Epic 6's architectural commitment: the grid is UIKit. SwiftUI's layout system wants a view per
/// cell and cannot carry a 1000 × 26 viewport, let alone the 10k-cell sheet the milestone asks for
/// at 60fps. Everything around the grid — the tab bar, the formula bar, navigation — stays SwiftUI;
/// this is the one place the app drops through. Epic 8 adds the gestures that make it an editor:
/// double-tap to edit, long-press-drag to select a range, and the fill handle.
struct SheetGridView: UIViewRepresentable {

    // MARK: - Input

    let sheet: SheetData?
    @Binding var selection: SheetSelection?
    var metrics: GridMetrics
    var showGridLines: Bool
    /// Epic 10 — how many rows and columns stay put while the rest scrolls.
    var frozen: FrozenPanes = FrozenPanes()
    /// Epic 10 — 1-based rows a column filter is hiding, laid out at zero height.
    var hiddenRows: Set<Int> = []
    /// Epic 10 — the columns carrying a filter, marked in the header.
    var filteredColumns: Set<Int> = []
    /// Whether the headers offer their structural commands at all. Off leaves them as labels that
    /// can still be tapped to select a whole row or column, which is not an edit.
    var allowsStructure: Bool = true
    /// Whether the editing affordances — the fill handle, the edit menu's destructive items — are
    /// offered at all. A read-only share gets a viewer, not a disabled editor.
    var isEditable: Bool
    /// True while the formula bar holds the keyboard, so the grid does not take first responder
    /// back and dismiss it out from under a half-typed value.
    var isEditingCell: Bool
    /// Whether the clipboard has anything in it, for the edit menu's Paste item.
    var canPaste: Bool
    /// Called on a double tap, and on Return from a hardware keyboard — the gesture that starts
    /// editing.
    var onActivate: (CellAddress) -> Void = { _ in }
    /// Called when the fill handle is released over `range`, which contains the selection.
    var onFill: (CellRange) -> Void = { _ in }
    var onCommand: (GridCommand) -> Void = { _ in }
    /// Epic 10 — everything a row or column header asks for.
    var onStructure: (StructureCommand) -> Void = { _ in }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> GridHostView {
        let view = GridHostView()
        view.onSelect = { [weak coordinator = context.coordinator] in coordinator?.select($0) }
        configure(view, context: context)
        apply(to: view)
        return view
    }

    func updateUIView(_ view: GridHostView, context: Context) {
        context.coordinator.selection = $selection
        configure(view, context: context)
        apply(to: view)
    }

    private func apply(to view: GridHostView) {
        view.apply(sheet: sheet, metrics: metrics, selection: selection,
                   showGridLines: showGridLines, frozen: frozen, hiddenRows: hiddenRows,
                   filteredColumns: filteredColumns)
    }

    private func configure(_ view: GridHostView, context: Context) {
        view.onActivate = onActivate
        view.onFill = onFill
        view.onCommand = onCommand
        view.onStructure = onStructure
        view.isEditable = isEditable
        view.isEditingCell = isEditingCell
        view.canPaste = canPaste
        view.allowsStructure = allowsStructure
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    // MARK: - Coordinator

    /// Carries the selection binding across the UIKit boundary. A class, because `makeUIView`'s
    /// escaping closure has to write to a binding that `updateUIView` may since have replaced.
    final class Coordinator {
        var selection: Binding<SheetSelection?>

        init(selection: Binding<SheetSelection?>) {
            self.selection = selection
        }

        func select(_ selection: SheetSelection?) {
            self.selection.wrappedValue = selection
        }
    }
}

// MARK: - GridHostView

/// Composes the scrolling canvas with the two frozen headers.
///
/// Layout, in one place because it is the part that is easy to get subtly wrong:
///
/// ```
///  ┌────────┬──────────────────────────┐
///  │ corner │ column header (frozen y) │
///  ├────────┼──────────────────────────┤
///  │  row   │                          │
///  │ header │   scroll view + canvas   │
///  │(frozen │                          │
///  │   x)   │                          │
///  └────────┴──────────────────────────┘
/// ```
///
/// The scroll view holds a content-sized *spacer* — an empty view that exists only to give
/// `contentSize` something to measure — and the canvas rides on top of it, repositioned to the
/// visible rectangle on every scroll. See ``GridCanvasView`` for why the canvas cannot simply be
/// the content view.
final class GridHostView: UIView {

    // MARK: - Callbacks

    var onSelect: (SheetSelection?) -> Void = { _ in }
    var onActivate: (CellAddress) -> Void = { _ in }
    var onFill: (CellRange) -> Void = { _ in }
    var onCommand: (GridCommand) -> Void = { _ in }
    var onStructure: (StructureCommand) -> Void = { _ in }

    // MARK: - Configuration

    var isEditable = false
    var canPaste = false
    /// Epic 10's feature flag, reaching the one place it could otherwise be routed around: the
    /// header menu and the resize drag are entry points of their own, not views a SwiftUI `if` can
    /// leave out.
    var allowsStructure = true

    /// Set while the formula bar is being typed into. The grid stops taking first responder then:
    /// a tap that dismissed the keyboard mid-value would lose whatever had been typed.
    var isEditingCell = false {
        didSet {
            guard isEditingCell, isFirstResponder else { return }
            resignFirstResponder()
        }
    }

    // MARK: - Subviews

    private let scrollView = UIScrollView()
    private let spacerView = UIView()
    private let canvasView = GridCanvasView()
    private let columnHeader = GridHeaderView(axis: .columns)
    private let rowHeader = GridHeaderView(axis: .rows)
    private let cornerView = UIView()

    /// Epic 10 — the three frozen panes, in the same order they are laid out: the block that never
    /// moves, the band that scrolls sideways only, and the band that scrolls up and down only.
    ///
    /// They are siblings of the scroll view rather than subviews of it, so the content passes
    /// *under* them. Each is an ordinary ``GridCanvasView`` handed a different content origin —
    /// there is no second renderer, only a fourth and fifth and sixth window onto the same sheet.
    private let frozenCorner = GridCanvasView()
    private let frozenRowBand = GridCanvasView()
    private let frozenColumnBand = GridCanvasView()
    /// The hairlines that say where the frozen region ends.
    private let frozenRowDivider = UIView()
    private let frozenColumnDivider = UIView()

    // MARK: - State

    private var sheet: SheetData?
    private var baseMetrics = GridMetrics()
    private var geometry: GridGeometry?
    private var selection: SheetSelection?
    private var showGridLines = true
    private var frozen = FrozenPanes()
    private var hiddenRows: Set<Int> = []

    /// A resize drag in progress: the sheet is laid out with this size in place of the stored one,
    /// so the column moves under the finger, and nothing is written until the finger lifts. Every
    /// intermediate width would otherwise be an undo entry and a save.
    private var resizePreview: (axis: GridHeaderView.Axis, index: Int, size: Double)?

    /// The zoom in progress, held separately so a pinch can be applied continuously and only
    /// committed to `baseMetrics` when the gesture ends.
    private var pinchStartZoom: Double = 1

    /// The drag currently running, if any. Both kinds move a corner around and both want the same
    /// edge auto-scrolling, so they share one piece of state.
    private enum Drag {
        /// Long-press-and-move: the selection's active corner follows the finger.
        case selecting(moved: Bool)
        /// The fill handle: the preview range grows away from the selection.
        case filling(source: CellRange)
    }
    private var drag: Drag?
    /// The finger's position in this view's coordinates, kept so the auto-scroll timer can carry on
    /// extending the drag while the finger is still.
    private var dragPoint: CGPoint = .zero
    private var autoScrollTimer: Timer?

    /// The range the fill handle has been dragged over, drawn as a preview until it is released.
    private var fillPreview: CellRange?

    private var fillPanGesture: UIPanGestureRecognizer?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    /// Set while a header menu is being raised, so the one interaction can serve both menus.
    private var pendingHeaderMenu: (axis: GridHeaderView.Axis, index: Int)?

    /// How far past the edge of the selection the fill handle can still be grabbed. The handle is
    /// drawn small — a fingertip is not.
    private static let fillHandleTouchRadius: CGFloat = 22
    /// How close to the edge of the viewport a drag has to get before the grid scrolls itself.
    private static let autoScrollMargin: CGFloat = 44

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        // Momentum scrolling in both axes at once, which is what a grid wants and what
        // `.decelerationRate(.normal)` gives.
        scrollView.decelerationRate = .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.addSubview(spacerView)
        scrollView.addSubview(canvasView)
        addSubview(scrollView)

        // Added before the headers so a frozen pane can never draw over the row numbers.
        for pane in [frozenColumnBand, frozenRowBand, frozenCorner] {
            // The panes are pictures, not controls: every touch belongs to the scroll view
            // underneath, and the gestures translate the coordinates instead. A pane that swallowed
            // touches would make the frozen cells unselectable.
            pane.isUserInteractionEnabled = false
            pane.isHidden = true
            addSubview(pane)
        }
        for divider in [frozenRowDivider, frozenColumnDivider] {
            divider.backgroundColor = .separator
            divider.isUserInteractionEnabled = false
            divider.isHidden = true
            addSubview(divider)
        }

        addSubview(columnHeader)
        addSubview(rowHeader)
        cornerView.backgroundColor = .secondarySystemBackground
        addSubview(cornerView)
        installHeaderCallbacks()

        addInteraction(editMenu)
        installGestures()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func installGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // Otherwise the first tap of a double-tap selects and the second edits, which is the same
        // outcome but flickers a selection onto the wrong cell on the way.
        tap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        scrollView.addGestureRecognizer(pinch)

        // Long-press-then-move rather than a plain pan: a pan would have to be arbitrated against
        // the scroll view's own, and losing that argument is how a grid ends up unable to scroll.
        // A press that has already been held is unambiguous, so scrolling is simply switched off
        // for its duration.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        press.allowableMovement = 12
        scrollView.addGestureRecognizer(press)

        let fill = UIPanGestureRecognizer(target: self, action: #selector(handleFillPan(_:)))
        fill.delegate = self
        scrollView.addGestureRecognizer(fill)
        fillPanGesture = fill
    }

    // MARK: - Input

    /// Applies a new render state. Cheap to call on every SwiftUI update: the geometry is only
    /// rebuilt when something it depends on actually changed.
    func apply(sheet: SheetData?, metrics: GridMetrics, selection: SheetSelection?,
               showGridLines: Bool, frozen: FrozenPanes = FrozenPanes(),
               hiddenRows: Set<Int> = [], filteredColumns: Set<Int> = []) {
        let geometryChanged = self.sheet != sheet || baseMetrics != metrics
            || self.hiddenRows != hiddenRows || geometry == nil
        let frozenChanged = self.frozen != frozen
        // A selection arriving from outside — undo, a fill, the reference box — may be somewhere
        // the user cannot see, so it is followed. A selection this view just made is already
        // visible, and scrolling to it would fight the finger.
        let arrivedFromOutside = selection != self.selection && drag == nil

        self.sheet = sheet
        self.baseMetrics = metrics
        self.selection = selection
        self.showGridLines = showGridLines
        self.frozen = frozen
        self.hiddenRows = hiddenRows

        if geometryChanged {
            rebuildGeometry()
        } else if frozenChanged {
            repositionCanvas()
        } else {
            refreshCanvas()
        }
        columnHeader.selection = selection
        rowHeader.selection = selection
        columnHeader.filteredColumns = filteredColumns
        // A resize is an edit, so it needs both: the right to write, and the epic switched on.
        columnHeader.isEditable = isEditable && allowsStructure
        rowHeader.isEditable = isEditable && allowsStructure

        if arrivedFromOutside, let active = selection?.active {
            scrollTo(active, animated: false)
        }
    }

    /// Wires the two headers to this view. Every one of these is a request, not an action — the
    /// grid does not own the workbook, and a resize is an edit like any other.
    private func installHeaderCallbacks() {
        columnHeader.onSelect = { [weak self] in self?.selectColumns($0...$0) }
        columnHeader.onExtend = { [weak self] index in
            guard let self, let anchor = self.selection?.anchor else { return }
            self.selectColumns(min(anchor.column, index)...max(anchor.column, index),
                               keepingAnchorAt: anchor.column)
        }
        columnHeader.onMenu = { [weak self] index, point in
            self?.presentHeaderMenu(axis: .columns, index: index,
                                    at: self?.columnHeader.convert(point, to: self) ?? point)
        }
        columnHeader.onResizePreview = { [weak self] index, size in
            self?.previewResize(axis: .columns, index: index, size: size)
        }
        columnHeader.onResizeCommit = { [weak self] index, size in
            self?.commitResize(axis: .columns, index: index, size: size)
        }

        rowHeader.onSelect = { [weak self] in self?.selectRows($0...$0) }
        rowHeader.onExtend = { [weak self] index in
            guard let self, let anchor = self.selection?.anchor else { return }
            self.selectRows(min(anchor.row, index)...max(anchor.row, index),
                            keepingAnchorAt: anchor.row)
        }
        rowHeader.onMenu = { [weak self] index, point in
            self?.presentHeaderMenu(axis: .rows, index: index,
                                    at: self?.rowHeader.convert(point, to: self) ?? point)
        }
        rowHeader.onResizePreview = { [weak self] index, size in
            self?.previewResize(axis: .rows, index: index, size: size)
        }
        rowHeader.onResizeCommit = { [weak self] index, size in
            self?.commitResize(axis: .rows, index: index, size: size)
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let scaled = baseMetrics.scaled
        let headerHeight = CGFloat(scaled.columnHeaderHeight)
        let headerWidth = CGFloat(scaled.rowHeaderWidth)

        cornerView.frame = CGRect(x: 0, y: 0, width: headerWidth, height: headerHeight)
        columnHeader.frame = CGRect(x: headerWidth, y: 0,
                                    width: bounds.width - headerWidth, height: headerHeight)
        rowHeader.frame = CGRect(x: 0, y: headerHeight,
                                 width: headerWidth, height: bounds.height - headerHeight)
        scrollView.frame = CGRect(x: headerWidth, y: headerHeight,
                                  width: bounds.width - headerWidth,
                                  height: bounds.height - headerHeight)
        columnHeader.labelFontSize = 11 * CGFloat(baseMetrics.zoom)
        rowHeader.labelFontSize = 11 * CGFloat(baseMetrics.zoom)
        for canvas in [canvasView, frozenCorner, frozenRowBand, frozenColumnBand] {
            canvas.baseFontSize = 13 * CGFloat(baseMetrics.zoom)
        }
        repositionCanvas()
    }

    // MARK: - Geometry

    /// The sheet as it should be laid out right now: the workbook's own sizes, with a resize drag's
    /// live size standing in for the stored one.
    private var effectiveSheet: SheetData? {
        guard let resizePreview, var sheet else { return sheet }
        // The preview is in on-screen points and the stored sizes are unzoomed, so it is divided
        // back out — otherwise a resize made while zoomed in would commit a much wider column than
        // the one the user dragged.
        let stored = resizePreview.size / max(baseMetrics.zoom, 0.01)
        let key = String(resizePreview.index - 1)
        switch resizePreview.axis {
        case .columns:
            var widths = sheet.colWidths ?? [:]
            widths[key] = stored
            sheet.colWidths = widths
        case .rows:
            var heights = sheet.rowHeights ?? [:]
            heights[key] = stored
            sheet.rowHeights = heights
        }
        return sheet
    }

    private func rebuildGeometry() {
        let geometry = GridGeometry(sheet: effectiveSheet, metrics: baseMetrics,
                                    hiddenRows: hiddenRows)
        self.geometry = geometry
        // The spacer is the only thing that establishes `contentSize`; a trailing margin keeps the
        // last column and row from sitting flush against the screen edge.
        let size = geometry.contentSize
        spacerView.frame = CGRect(origin: .zero,
                                  size: CGSize(width: size.width + 40, height: size.height + 40))
        scrollView.contentSize = spacerView.frame.size
        columnHeader.geometry = geometry
        rowHeader.geometry = geometry
        repositionCanvas()
    }

    /// Where the frozen panes go and how a touch maps through them. See ``FrozenPaneLayout``.
    private var paneLayout: FrozenPaneLayout {
        FrozenPaneLayout(frozen: frozen, geometry: geometry, viewport: scrollView.bounds.size,
                         contentOffset: scrollView.contentOffset)
    }

    /// Moves the canvas over the visible rectangle and hands it the matching content origin.
    ///
    /// With panes frozen the viewport is in four parts, and each is the same renderer pointed at a
    /// different content origin: the corner shows the top-left of the sheet and never moves, the
    /// two bands each follow one axis, and the main canvas sits below and right of them showing
    /// content offset by the frozen extent. The panes are drawn *over* the scroll view, so the
    /// content passes underneath them — see the touch translation in ``contentPoint(fromViewPoint:)``.
    private func repositionCanvas() {
        guard geometry != nil else { return }
        let layout = paneLayout
        let origin = scrollView.frame.origin

        canvasView.frame = layout.mainFrame
        canvasView.contentOrigin = layout.mainContentOrigin

        // The panes are laid out in viewport coordinates and live in this view's, so each frame is
        // shifted past the two headers.
        for (pane, part, visible) in [
            (frozenCorner, layout.corner, layout.hasFrozenRows && layout.hasFrozenColumns),
            (frozenRowBand, layout.rowBand, layout.hasFrozenRows),
            (frozenColumnBand, layout.columnBand, layout.hasFrozenColumns),
        ] {
            pane.isHidden = !visible
            pane.frame = part.frame.offsetBy(dx: origin.x, dy: origin.y)
            pane.contentOrigin = part.contentOrigin
        }

        let hairline = 1 / (window?.screen.scale ?? 2)
        frozenRowDivider.isHidden = !layout.hasFrozenRows
        frozenRowDivider.frame = CGRect(x: 0, y: origin.y + layout.frozenSize.height,
                                        width: bounds.width, height: hairline)
        frozenColumnDivider.isHidden = !layout.hasFrozenColumns
        frozenColumnDivider.frame = CGRect(x: origin.x + layout.frozenSize.width, y: 0,
                                           width: hairline, height: bounds.height)

        columnHeader.contentOffset = scrollView.contentOffset.x
        columnHeader.frozen = (frozen.columns, layout.frozenSize.width)
        rowHeader.contentOffset = scrollView.contentOffset.y
        rowHeader.frozen = (frozen.rows, layout.frozenSize.height)
        refreshCanvas()
    }

    private func refreshCanvas() {
        guard let geometry else { return }
        let model = GridRenderModel(sheet: effectiveSheet, geometry: geometry,
                                    selection: selection, showGridLines: showGridLines,
                                    fillPreview: fillPreview,
                                    showsFillHandle: isEditable)
        canvasView.model = model
        for pane in [frozenCorner, frozenRowBand, frozenColumnBand] where !pane.isHidden {
            pane.model = model
        }
    }

    // MARK: - Hit testing

    /// The address under a point in the scroll view's content coordinates, resolved through a
    /// merge.
    ///
    /// A tap inside a merged block selects the block, i.e. its anchor. Selecting the covered cell
    /// instead would put the highlight on a cell that draws nothing and edit a value the user
    /// cannot see.
    private func address(atContentPoint point: CGPoint) -> CellAddress? {
        guard let geometry, point.x >= 0, point.y >= 0 else { return nil }
        let address = geometry.address(at: point)
        if let anchorID = sheet?.cells[address.id]?.mergeAnchor,
           let anchor = CellAddress(anchorID) {
            return anchor
        }
        return address
    }

    /// Converts a point in this view's coordinates into the scroll view's content coordinates,
    /// through whatever is frozen. See ``FrozenPaneLayout/contentPoint(fromViewportPoint:)``.
    private func contentPoint(fromViewPoint point: CGPoint) -> CGPoint {
        paneLayout.contentPoint(fromViewportPoint:
            CGPoint(x: point.x - scrollView.frame.minX, y: point.y - scrollView.frame.minY))
    }

    /// The inverse: where a content point currently shows on screen, or nil when nothing is
    /// showing it.
    private func viewPoint(fromContentPoint point: CGPoint) -> CGPoint? {
        paneLayout.viewportPoint(fromContentPoint: point).map {
            CGPoint(x: $0.x + scrollView.frame.minX, y: $0.y + scrollView.frame.minY)
        }
    }

    /// The fill handle's touch target, in this view's coordinates.
    ///
    /// Computed from the same merge-aware rectangle the canvas draws the handle in, so the two
    /// cannot end up in different places on a selection that ends on a merged cell.
    private func fillHandleTouchRect() -> CGRect? {
        guard isEditable, let geometry, let selection else { return nil }
        let frame = geometry.rect(for: selection.range, cells: sheet?.cells)
        guard let corner = viewPoint(fromContentPoint: CGPoint(x: frame.maxX, y: frame.maxY)) else {
            return nil
        }
        let radius = Self.fillHandleTouchRadius
        return CGRect(x: corner.x - radius, y: corner.y - radius,
                      width: radius * 2, height: radius * 2)
    }

    // MARK: - Header selection

    /// How far a whole-column or whole-row selection actually reaches.
    ///
    /// The web app selects to `MAX_ROWS`, all 65,536 of them. That cannot be copied here: every
    /// command walks `selection.range.addresses`, so a column selected to the format's maximum
    /// would ask the formatter to create 65,536 cells from one tap. The laid-out extent is what the
    /// user can see and scroll to, it already covers everything populated, and it is bounded.
    private var selectionExtent: (columns: Int, rows: Int) {
        geometry?.extent ?? (26, 100)
    }

    private func selectColumns(_ columns: ClosedRange<Int>, keepingAnchorAt anchor: Int? = nil) {
        takeFirstResponderIfIdle()
        let rows = selectionExtent.rows
        let anchorColumn = anchor ?? columns.lowerBound
        let activeColumn = anchorColumn == columns.lowerBound ? columns.upperBound : columns.lowerBound
        update(selection: SheetSelection(anchor: CellAddress(column: anchorColumn, row: 1),
                                         active: CellAddress(column: activeColumn, row: rows)))
    }

    private func selectRows(_ rows: ClosedRange<Int>, keepingAnchorAt anchor: Int? = nil) {
        takeFirstResponderIfIdle()
        let columns = selectionExtent.columns
        let anchorRow = anchor ?? rows.lowerBound
        let activeRow = anchorRow == rows.lowerBound ? rows.upperBound : rows.lowerBound
        update(selection: SheetSelection(anchor: CellAddress(column: 1, row: anchorRow),
                                         active: CellAddress(column: columns, row: activeRow)))
    }

    // MARK: - Resizing

    private func previewResize(axis: GridHeaderView.Axis, index: Int, size: Double) {
        resizePreview = (axis, index, size)
        rebuildGeometry()
    }

    private func commitResize(axis: GridHeaderView.Axis, index: Int, size: Double) {
        // The preview is dropped but the geometry is deliberately *not* rebuilt here: the workbook
        // is about to come back with the new size in it, and rebuilding first would snap the column
        // to its old width for one frame on the way.
        resizePreview = nil
        let stored = size / max(baseMetrics.zoom, 0.01)
        // A drag on a header inside the selection resizes all of it, which is how a user makes six
        // columns the same width without doing it six times.
        switch axis {
        case .columns:
            let range = selection?.range.columns.contains(index) == true
                ? selection!.range.columns : index...index
            onStructure(.resizeColumns(range, stored))
        case .rows:
            let range = selection?.range.rows.contains(index) == true
                ? selection!.range.rows : index...index
            onStructure(.resizeRows(range, stored))
        }
    }

    // MARK: - Gestures

    // Both taps resolve through this view's coordinates rather than the scroll view's, because a
    // touch landing on a frozen pane is not at the offset the scroll view would report.

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = contentPoint(fromViewPoint: recognizer.location(in: self))
        guard let address = address(atContentPoint: point) else { return }
        takeFirstResponderIfIdle()
        update(selection: SheetSelection(address))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let point = contentPoint(fromViewPoint: recognizer.location(in: self))
        guard let address = address(atContentPoint: point) else { return }
        update(selection: SheetSelection(address))
        onActivate(address)
    }

    /// Epic 8 — "Range selection by drag".
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)
        guard let address = address(atContentPoint: contentPoint(fromViewPoint: viewPoint)) else {
            return
        }

        switch recognizer.state {
        case .began:
            takeFirstResponderIfIdle()
            // Pressing inside an existing block keeps its anchor, so a range can be adjusted
            // without redrawing it from one corner.
            if selection?.range.contains(address) != true || selection?.isSingleCell != false {
                update(selection: SheetSelection(address))
            }
            beginDrag(.selecting(moved: false), at: viewPoint)

        case .changed:
            guard case .selecting = drag, let anchor = selection?.anchor else { return }
            dragPoint = viewPoint
            guard address != selection?.active else { return }
            drag = .selecting(moved: true)
            update(selection: SheetSelection(anchor: anchor, active: address))

        case .ended, .cancelled, .failed:
            let moved: Bool
            if case .selecting(let didMove) = drag { moved = didMove } else { moved = false }
            endDrag()
            // A press that never moved was not a range selection — it was a request for the menu.
            if !moved, recognizer.state == .ended {
                presentEditMenu(at: viewPoint)
            }

        default:
            break
        }
    }

    /// Epic 8 — "Fill handle (drag to fill, series detection)".
    @objc private func handleFillPan(_ recognizer: UIPanGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)

        switch recognizer.state {
        case .began:
            guard let source = selection?.range else { return }
            beginDrag(.filling(source: source), at: viewPoint)
            updateFillPreview(at: viewPoint)

        case .changed:
            guard case .filling = drag else { return }
            dragPoint = viewPoint
            updateFillPreview(at: viewPoint)

        case .ended:
            guard case .filling(let source) = drag else { return }
            let preview = fillPreview
            endDrag()
            if let preview, preview != source { onFill(preview) }

        case .cancelled, .failed:
            endDrag()

        default:
            break
        }
    }

    /// Grows the preview from the selection towards the finger, along one axis only.
    ///
    /// Constrained to the axis with the larger movement because a fill has one series to continue:
    /// a block dragged diagonally has no single answer, and guessing one is worse than choosing the
    /// direction the user moved furthest in.
    private func updateFillPreview(at viewPoint: CGPoint) {
        guard case .filling(let source) = drag,
              let address = address(atContentPoint: contentPoint(fromViewPoint: viewPoint)) else {
            return
        }

        let rowOverflow = address.row > source.end.row ? address.row - source.end.row
            : (address.row < source.start.row ? source.start.row - address.row : 0)
        let columnOverflow = address.column > source.end.column ? address.column - source.end.column
            : (address.column < source.start.column ? source.start.column - address.column : 0)

        let preview: CellRange
        if rowOverflow == 0 && columnOverflow == 0 {
            preview = source
        } else if rowOverflow >= columnOverflow {
            let row = address.row
            preview = source.union(CellRange(CellAddress(column: source.start.column, row: row),
                                             CellAddress(column: source.end.column, row: row)))
        } else {
            let column = address.column
            preview = source.union(CellRange(CellAddress(column: column, row: source.start.row),
                                             CellAddress(column: column, row: source.end.row)))
        }

        guard preview != fillPreview else { return }
        fillPreview = preview
        refreshCanvas()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartZoom = baseMetrics.zoom
        case .changed, .ended:
            let zoom = (pinchStartZoom * Double(recognizer.scale))
                .clamped(to: GridMetrics.zoomRange)
            guard zoom != baseMetrics.zoom else { return }
            // The cell under the pinch centre is held in place: rescaling around the content
            // origin instead would throw the user's place away on every zoom.
            let anchor = scrollView.contentOffset
            let previous = baseMetrics.zoom
            baseMetrics.zoom = zoom
            rebuildGeometry()
            let factor = zoom / previous
            scrollView.contentOffset = CGPoint(
                x: min(max(0, anchor.x * factor),
                       max(0, scrollView.contentSize.width - scrollView.bounds.width)),
                y: min(max(0, anchor.y * factor),
                       max(0, scrollView.contentSize.height - scrollView.bounds.height))
            )
            setNeedsLayout()
        default:
            break
        }
    }

    @objc private func handleMemoryWarning() {
        GridStyleResolver.flushCaches()
    }

    // MARK: - Drag plumbing

    private func beginDrag(_ kind: Drag, at viewPoint: CGPoint) {
        drag = kind
        dragPoint = viewPoint
        // Cancels any scroll already under way and stops another from starting. Re-enabled in
        // `endDrag`, which every terminal state routes through.
        scrollView.isScrollEnabled = false
        startAutoScroll()
    }

    private func endDrag() {
        drag = nil
        fillPreview = nil
        stopAutoScroll()
        scrollView.isScrollEnabled = true
        refreshCanvas()
    }

    /// Scrolls the grid while a drag is held near the edge of the viewport, so a range can reach
    /// past what is on screen without the user having to let go.
    private func startAutoScroll() {
        stopAutoScroll()
        // Scheduled in `.common` so it keeps firing while the drag is tracking, which puts the run
        // loop in tracking mode and would otherwise stall a default-mode timer completely.
        let timer = Timer(timeInterval: 1.0 / 60, target: self,
                          selector: #selector(stepAutoScroll), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    @objc private func stepAutoScroll() {
        guard drag != nil else { return }
        let frame = scrollView.frame
        let margin = Self.autoScrollMargin
        // Speed rises towards the edge, so a drag can creep or race depending on how far out the
        // finger is held.
        func velocity(_ position: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            if position < low + margin { return -(low + margin - position) / margin * 14 }
            if position > high - margin { return (position - (high - margin)) / margin * 14 }
            return 0
        }
        let dx = velocity(dragPoint.x, frame.minX, frame.maxX)
        let dy = velocity(dragPoint.y, frame.minY, frame.maxY)
        guard dx != 0 || dy != 0 else { return }

        let maxX = max(0, scrollView.contentSize.width - frame.width)
        let maxY = max(0, scrollView.contentSize.height - frame.height)
        let offset = CGPoint(x: min(max(0, scrollView.contentOffset.x + dx), maxX),
                             y: min(max(0, scrollView.contentOffset.y + dy), maxY))
        guard offset != scrollView.contentOffset else { return }
        scrollView.contentOffset = offset

        // The finger has not moved, but the grid under it has, so the drag target has to be
        // recomputed against the new offset.
        switch drag {
        case .selecting:
            guard let anchor = selection?.anchor,
                  let address = address(atContentPoint: contentPoint(fromViewPoint: dragPoint)),
                  address != selection?.active else { return }
            drag = .selecting(moved: true)
            update(selection: SheetSelection(anchor: anchor, active: address))
        case .filling:
            updateFillPreview(at: dragPoint)
        case nil:
            break
        }
    }

    // MARK: - Selection

    /// Writes a selection through to the canvas, the headers and SwiftUI in one place, so the three
    /// cannot disagree about what is selected.
    private func update(selection newValue: SheetSelection) {
        guard selection != newValue else { return }
        selection = newValue
        columnHeader.selection = newValue
        rowHeader.selection = newValue
        refreshCanvas()
        onSelect(newValue)
    }

    /// Brings `address` into view, used when a selection changes from outside the grid.
    ///
    /// The rectangle handed to the scroll view is shifted back by the frozen extent, because the
    /// scrolling region begins where the frozen panes end: without that, a cell scrolled "into
    /// view" can land underneath the frozen band and stay invisible.
    func scrollTo(_ address: CellAddress, animated: Bool) {
        guard let geometry, scrollView.bounds.width > 0 else { return }
        let frozenSize = paneLayout.frozenSize
        let cell = geometry.rect(for: address)
        // Already showing in a frozen pane: it cannot be scrolled to, and does not need to be.
        if cell.maxX <= frozenSize.width || cell.maxY <= frozenSize.height {
            return
        }
        let rect = cell.offsetBy(dx: -frozenSize.width, dy: -frozenSize.height)
            .insetBy(dx: -8, dy: -8)
        guard !scrollView.bounds.contains(rect) else { return }
        scrollView.scrollRectToVisible(rect, animated: animated)
    }

    // MARK: - Responder chain

    override var canBecomeFirstResponder: Bool { true }

    private func takeFirstResponderIfIdle() {
        guard !isEditingCell, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    /// Hardware-keyboard navigation. Arrows move, shift-arrows extend, Return and Tab do what they
    /// do in every spreadsheet.
    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [],
                         action: #selector(moveSelection(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [],
                         action: #selector(moveSelection(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [],
                         action: #selector(moveSelection(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [],
                         action: #selector(moveSelection(_:))),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: .shift,
                         action: #selector(extendSelection(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: .shift,
                         action: #selector(extendSelection(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .shift,
                         action: #selector(extendSelection(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .shift,
                         action: #selector(extendSelection(_:))),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(activateSelection)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(moveSelection(_:))),
        ]
        if isEditable {
            commands.append(UIKeyCommand(input: "z", modifierFlags: .command,
                                         action: #selector(performUndo)))
            commands.append(UIKeyCommand(input: "z", modifierFlags: [.command, .shift],
                                         action: #selector(performRedo)))
            // Backspace and forward-delete both empty the selection. UIKit routes ⌘X to `cut(_:)`
            // on its own, but nothing routes the delete keys anywhere — a view that is not a text
            // field never hears them otherwise.
            commands.append(UIKeyCommand(input: "\u{8}", modifierFlags: [],
                                         action: #selector(clearSelection)))
            commands.append(UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [],
                                         action: #selector(clearSelection)))
        }
        // Arrows, Tab and Return all mean something to UIKit's own focus system. In a grid they
        // mean something else, and the grid has to win.
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func moveSelection(_ command: UIKeyCommand) {
        guard let active = selection?.active else { return }
        let moved = active.offset(columns: columnDelta(for: command), rows: rowDelta(for: command))
        update(selection: SheetSelection(moved))
        scrollTo(moved, animated: false)
    }

    @objc private func extendSelection(_ command: UIKeyCommand) {
        guard let selection else { return }
        let moved = selection.active.offset(columns: columnDelta(for: command),
                                            rows: rowDelta(for: command))
        update(selection: SheetSelection(anchor: selection.anchor, active: moved))
        scrollTo(moved, animated: false)
    }

    private func columnDelta(for command: UIKeyCommand) -> Int {
        switch command.input {
        case UIKeyCommand.inputLeftArrow:  return -1
        case UIKeyCommand.inputRightArrow: return 1
        case "\t":                         return 1
        default:                           return 0
        }
    }

    private func rowDelta(for command: UIKeyCommand) -> Int {
        switch command.input {
        case UIKeyCommand.inputUpArrow:   return -1
        case UIKeyCommand.inputDownArrow: return 1
        default:                          return 0
        }
    }

    @objc private func activateSelection() {
        guard let active = selection?.active else { return }
        onActivate(active)
    }

    @objc private func performUndo() { onCommand(.undo) }
    @objc private func performRedo() { onCommand(.redo) }
    @objc private func clearSelection() { onCommand(.clear) }

    // MARK: - Clipboard

    // Implemented as responder actions rather than as key commands so ⌘C / ⌘X / ⌘V and the edit
    // menu reach the same code, and so the menu greys the items out on its own.

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return selection != nil
        case #selector(cut(_:)), #selector(delete(_:)):
            return isEditable && selection != nil
        case #selector(paste(_:)):
            return isEditable && canPaste
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) { onCommand(.copy) }
    override func cut(_ sender: Any?) { onCommand(.cut) }
    override func paste(_ sender: Any?) { onCommand(.paste) }
    override func delete(_ sender: Any?) { onCommand(.clear) }

    private func presentEditMenu(at viewPoint: CGPoint) {
        takeFirstResponderIfIdle()
        pendingHeaderMenu = nil
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                               sourcePoint: viewPoint))
    }

    // MARK: - Header menu

    /// Epic 10 — which header the menu being shown belongs to, or nil when it is the cell menu.
    ///
    /// One interaction serves both because they are the same affordance in two places, and because
    /// two `UIEditMenuInteraction`s on one view would race to present.
    private func presentHeaderMenu(axis: GridHeaderView.Axis, index: Int, at viewPoint: CGPoint) {
        guard allowsStructure else { return }
        takeFirstResponderIfIdle()
        pendingHeaderMenu = (axis, index)
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                               sourcePoint: viewPoint))
    }

    /// The menu a press on a row or column header raises.
    ///
    /// Ordered the way the web app's `HeaderContextMenu` orders it — sort, filter, insert, delete,
    /// hide — because the two apps are used by the same people and muscle memory is worth more than
    /// a tidier grouping. Freeze is appended: the web app has no equivalent, and a header is where
    /// a phone user goes looking for it.
    private func headerMenu(axis: GridHeaderView.Axis, index: Int) -> UIMenu {
        let count = axis == .columns
            ? (selection?.range.columns.contains(index) == true ? selection!.range.columnCount : 1)
            : (selection?.range.rows.contains(index) == true ? selection!.range.rowCount : 1)
        let noun = axis == .columns
            ? (count > 1 ? "\(count) Columns" : "Column")
            : (count > 1 ? "\(count) Rows" : "Row")

        var sections: [UIMenuElement] = []

        if axis == .columns {
            sections.append(UIMenu(title: "", options: .displayInline, children: [
                action("Sort A → Z", "arrow.down") { [weak self] in
                    self?.onStructure(.sort(column: index, ascending: true))
                },
                action("Sort Z → A", "arrow.up") { [weak self] in
                    self?.onStructure(.sort(column: index, ascending: false))
                },
            ]))

            var filtering = [action("Filter\u{2026}", "line.3.horizontal.decrease") { [weak self] in
                self?.onStructure(.filter(column: index))
            }]
            if columnHeader.filteredColumns.contains(index) {
                filtering.append(action("Clear Filter", "xmark") { [weak self] in
                    self?.onStructure(.clearFilter(column: index))
                })
            }
            sections.append(UIMenu(title: "", options: .displayInline, children: filtering))
        }

        guard isEditable else { return UIMenu(children: sections) }

        let isColumns = axis == .columns
        sections.append(UIMenu(title: "", options: .displayInline, children: [
            action(isColumns ? "Insert \(noun) Left" : "Insert \(noun) Above",
                   isColumns ? "arrow.left" : "arrow.up") { [weak self] in
                self?.onStructure(isColumns ? .insertColumns(before: true) : .insertRows(before: true))
            },
            action(isColumns ? "Insert \(noun) Right" : "Insert \(noun) Below",
                   isColumns ? "arrow.right" : "arrow.down") { [weak self] in
                self?.onStructure(isColumns ? .insertColumns(before: false) : .insertRows(before: false))
            },
        ]))

        var removal = [
            UIAction(title: "Delete \(noun)", image: UIImage(systemName: "trash"),
                     attributes: .destructive) { [weak self] _ in
                self?.onStructure(isColumns ? .deleteColumns : .deleteRows)
            },
            action("Hide \(noun)", "eye.slash") { [weak self] in
                self?.onStructure(isColumns ? .hideColumns : .hideRows)
            },
        ]
        if selectionHidesAnything {
            removal.append(action("Show Hidden", "eye") { [weak self] in
                self?.onStructure(.show)
            })
        }
        sections.append(UIMenu(title: "", options: .displayInline, children: removal))

        sections.append(UIMenu(title: "", options: .displayInline, children: [
            frozen.isEmpty
                ? action("Freeze Up To Here", "lock") { [weak self] in
                    self?.onStructure(.freezeToSelection)
                }
                : action("Unfreeze Panes", "lock.open") { [weak self] in
                    self?.onStructure(.unfreeze)
                },
        ]))

        return UIMenu(children: sections)
    }

    /// True when the selection covers a row or column stored at zero size, so the menu can offer to
    /// put it back. A hidden header has no edge left to grab, so the menu is the only way out.
    private var selectionHidesAnything: Bool {
        guard let range = selection?.range, let sheet else { return false }
        return range.rows.contains { sheet.height(ofRow: $0 - 1) == 0 }
            || range.columns.contains { sheet.width(ofColumn: $0 - 1) == 0 }
    }

    private func action(_ title: String, _ symbol: String,
                        handler: @escaping () -> Void) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol)) { _ in handler() }
    }
}

// MARK: - GridHostView + UIEditMenuInteractionDelegate

extension GridHostView: UIEditMenuInteractionDelegate {

    /// The menu a long press raises. Built explicitly rather than from `suggestedActions` so the
    /// order and the wording are the app's, and so Clear reads as "Clear" rather than "Delete" —
    /// it empties the cells and keeps their formatting.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        if let pendingHeaderMenu {
            return headerMenu(axis: pendingHeaderMenu.axis, index: pendingHeaderMenu.index)
        }

        var actions: [UIMenuElement] = []
        if isEditable {
            actions.append(UIAction(title: "Cut", image: UIImage(systemName: "scissors")) {
                [weak self] _ in self?.onCommand(.cut)
            })
        }
        actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) {
            [weak self] _ in self?.onCommand(.copy)
        })
        if isEditable {
            let paste = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) {
                [weak self] _ in self?.onCommand(.paste)
            }
            paste.attributes = canPaste ? [] : .disabled
            actions.append(paste)
            actions.append(UIAction(title: "Clear", image: UIImage(systemName: "eraser"),
                                    attributes: .destructive) {
                [weak self] _ in self?.onCommand(.clear)
            })
        }
        return UIMenu(children: actions)
    }
}

// MARK: - GridHostView + UIGestureRecognizerDelegate

extension GridHostView: UIGestureRecognizerDelegate {

    /// The fill pan only ever sees touches that start on the handle. Refusing the touch outright —
    /// rather than beginning and then cancelling — is what keeps the scroll view's own pan free to
    /// recognise immediately everywhere else on the grid.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === fillPanGesture else { return true }
        guard let rect = fillHandleTouchRect() else { return false }
        return rect.contains(touch.location(in: self))
    }
}

// MARK: - GridHostView + UIScrollViewDelegate

extension GridHostView: UIScrollViewDelegate {

    /// Redraws on every scroll callback.
    ///
    /// This is the frame loop, and it is why the canvas has to stay viewport-sized: the work per
    /// callback is one `draw(_:)` over a screen's worth of cells, which is bounded by the display
    /// rather than by the workbook. A `CADisplayLink` would add nothing — `scrollViewDidScroll` is
    /// already called once per displayed frame while scrolling.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        repositionCanvas()
    }
}
