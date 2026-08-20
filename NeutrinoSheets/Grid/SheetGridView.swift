import SwiftUI
import UIKit

// MARK: - GridCommand

/// A clipboard or history command raised by the grid — from the edit menu, a key command, or a
/// hardware keyboard shortcut. The grid does not own the workbook, so it asks rather than acts.
enum GridCommand {
    case cut, copy, paste, clear, undo, redo
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

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> GridHostView {
        let view = GridHostView()
        view.onSelect = { [weak coordinator = context.coordinator] in coordinator?.select($0) }
        configure(view, context: context)
        view.apply(sheet: sheet, metrics: metrics, selection: selection, showGridLines: showGridLines)
        return view
    }

    func updateUIView(_ view: GridHostView, context: Context) {
        context.coordinator.selection = $selection
        configure(view, context: context)
        view.apply(sheet: sheet, metrics: metrics, selection: selection, showGridLines: showGridLines)
    }

    private func configure(_ view: GridHostView, context: Context) {
        view.onActivate = onActivate
        view.onFill = onFill
        view.onCommand = onCommand
        view.isEditable = isEditable
        view.isEditingCell = isEditingCell
        view.canPaste = canPaste
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

    // MARK: - Configuration

    var isEditable = false
    var canPaste = false

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

    // MARK: - State

    private var sheet: SheetData?
    private var baseMetrics = GridMetrics()
    private var geometry: GridGeometry?
    private var selection: SheetSelection?
    private var showGridLines = true

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

        addSubview(columnHeader)
        addSubview(rowHeader)
        cornerView.backgroundColor = .secondarySystemBackground
        addSubview(cornerView)

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
               showGridLines: Bool) {
        let geometryChanged = self.sheet != sheet || baseMetrics != metrics || geometry == nil
        // A selection arriving from outside — undo, a fill, the reference box — may be somewhere
        // the user cannot see, so it is followed. A selection this view just made is already
        // visible, and scrolling to it would fight the finger.
        let arrivedFromOutside = selection != self.selection && drag == nil

        self.sheet = sheet
        self.baseMetrics = metrics
        self.selection = selection
        self.showGridLines = showGridLines

        if geometryChanged {
            rebuildGeometry()
        } else {
            refreshCanvas()
        }
        columnHeader.selection = selection
        rowHeader.selection = selection

        if arrivedFromOutside, let active = selection?.active {
            scrollTo(active, animated: false)
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
        canvasView.baseFontSize = 13 * CGFloat(baseMetrics.zoom)
        repositionCanvas()
    }

    // MARK: - Geometry

    private func rebuildGeometry() {
        let geometry = GridGeometry(sheet: sheet, metrics: baseMetrics)
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

    /// Moves the canvas over the visible rectangle and hands it the matching content origin.
    private func repositionCanvas() {
        guard geometry != nil else { return }
        let offset = scrollView.contentOffset
        let visible = CGRect(origin: offset, size: scrollView.bounds.size)
        canvasView.frame = visible
        canvasView.contentOrigin = offset
        columnHeader.contentOffset = offset.x
        rowHeader.contentOffset = offset.y
        refreshCanvas()
    }

    private func refreshCanvas() {
        guard let geometry else { return }
        canvasView.model = GridRenderModel(sheet: sheet, geometry: geometry,
                                           selection: selection, showGridLines: showGridLines,
                                           fillPreview: fillPreview,
                                           showsFillHandle: isEditable)
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

    /// Converts a point in this view's coordinates into the scroll view's content coordinates.
    private func contentPoint(fromViewPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - scrollView.frame.minX + scrollView.contentOffset.x,
                y: point.y - scrollView.frame.minY + scrollView.contentOffset.y)
    }

    /// The fill handle's touch target, in content coordinates.
    ///
    /// Computed from the same merge-aware rectangle the canvas draws the handle in, so the two
    /// cannot end up in different places on a selection that ends on a merged cell.
    private func fillHandleTouchRect() -> CGRect? {
        guard isEditable, let geometry, let selection else { return nil }
        let frame = geometry.rect(for: selection.range, cells: sheet?.cells)
        let radius = Self.fillHandleTouchRadius
        return CGRect(x: frame.maxX - radius, y: frame.maxY - radius,
                      width: radius * 2, height: radius * 2)
    }

    // MARK: - Gestures

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let address = address(atContentPoint: recognizer.location(in: scrollView)) else {
            return
        }
        takeFirstResponderIfIdle()
        update(selection: SheetSelection(address))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let address = address(atContentPoint: recognizer.location(in: scrollView)) else {
            return
        }
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
    func scrollTo(_ address: CellAddress, animated: Bool) {
        guard let geometry, scrollView.bounds.width > 0 else { return }
        let rect = geometry.rect(for: address).insetBy(dx: -8, dy: -8)
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
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                               sourcePoint: viewPoint))
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
        return rect.contains(touch.location(in: scrollView))
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
