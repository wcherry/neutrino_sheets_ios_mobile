import SwiftUI
import UIKit

// MARK: - SheetGridView

/// The spreadsheet grid, hosted in SwiftUI.
///
/// Epic 6's architectural commitment: the grid is UIKit. SwiftUI's layout system wants a view per
/// cell and cannot carry a 1000 × 26 viewport, let alone the 10k-cell sheet the milestone asks for
/// at 60fps. Everything around the grid — the tab bar, the formula bar, navigation — stays SwiftUI;
/// this is the one place the app drops through.
struct SheetGridView: UIViewRepresentable {

    // MARK: - Input

    let sheet: SheetData?
    @Binding var selection: CellAddress?
    var metrics: GridMetrics
    var showGridLines: Bool
    /// Called on a second tap of the already-selected cell — the gesture that starts editing.
    var onActivate: (CellAddress) -> Void = { _ in }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> GridHostView {
        let view = GridHostView()
        view.onSelect = { context.coordinator.select($0) }
        view.onActivate = onActivate
        view.apply(sheet: sheet, metrics: metrics, selection: selection, showGridLines: showGridLines)
        return view
    }

    func updateUIView(_ view: GridHostView, context: Context) {
        context.coordinator.selection = $selection
        view.onActivate = onActivate
        view.apply(sheet: sheet, metrics: metrics, selection: selection, showGridLines: showGridLines)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    // MARK: - Coordinator

    /// Carries the selection binding across the UIKit boundary. A class, because `makeUIView`'s
    /// escaping closure has to write to a binding that `updateUIView` may since have replaced.
    final class Coordinator {
        var selection: Binding<CellAddress?>

        init(selection: Binding<CellAddress?>) {
            self.selection = selection
        }

        func select(_ address: CellAddress?) {
            selection.wrappedValue = address
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

    var onSelect: (CellAddress?) -> Void = { _ in }
    var onActivate: (CellAddress) -> Void = { _ in }

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
    private var selection: CellAddress?
    private var showGridLines = true

    /// The zoom in progress, held separately so a pinch can be applied continuously and only
    /// committed to `baseMetrics` when the gesture ends.
    private var pinchStartZoom: Double = 1

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

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scrollView.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        scrollView.addGestureRecognizer(pinch)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Input

    /// Applies a new render state. Cheap to call on every SwiftUI update: the geometry is only
    /// rebuilt when something it depends on actually changed.
    func apply(sheet: SheetData?, metrics: GridMetrics, selection: CellAddress?, showGridLines: Bool) {
        let geometryChanged = self.sheet != sheet || baseMetrics != metrics || geometry == nil
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
                                           selection: selection, showGridLines: showGridLines)
    }

    // MARK: - Gestures

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let geometry else { return }
        let point = recognizer.location(in: scrollView)
        guard point.x >= 0, point.y >= 0 else { return }
        var address = geometry.address(at: point)

        // A tap inside a merged block selects the block, i.e. its anchor. Selecting the covered
        // cell instead would put the highlight on a cell that draws nothing and edit a value the
        // user cannot see.
        if let anchorID = sheet?.cells[address.id]?.mergeAnchor,
           let anchor = CellAddress(anchorID) {
            address = anchor
        }

        if address == selection {
            onActivate(address)
        } else {
            selection = address
            columnHeader.selection = address
            rowHeader.selection = address
            refreshCanvas()
            onSelect(address)
        }
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

    // MARK: - Scrolling to a cell

    /// Brings `address` into view, used when a selection changes from outside the grid.
    func scrollTo(_ address: CellAddress, animated: Bool) {
        guard let geometry else { return }
        let rect = geometry.rect(for: address).insetBy(dx: -8, dy: -8)
        scrollView.scrollRectToVisible(rect, animated: animated)
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
