import CoreGraphics
import Foundation

// MARK: - FrozenPaneLayout

/// Epic 10 — where each pane goes when rows or columns are frozen, and how a touch on one maps back
/// to a cell.
///
/// A value type rather than code inside ``GridHostView`` because it is arithmetic, and arithmetic
/// that can only be checked by looking at a simulator is arithmetic that drifts. The same reasoning
/// put ``GridGeometry`` in its own type.
///
/// The model: the viewport is divided into four regions by the frozen extent.
///
/// ```
///  ┌──────────┬───────────────────────┐
///  │  corner  │      row band         │  ← frozen rows, scrolls sideways only
///  │  (fixed) │                       │
///  ├──────────┼───────────────────────┤
///  │  column  │                       │
///  │   band   │      main canvas      │  ← scrolls both ways
///  │          │                       │
///  └──────────┴───────────────────────┘
///     ↑ frozen columns, scrolls vertically only
/// ```
///
/// The scroll view keeps its full content size, so a content offset of *n* means the same thing as
/// it did before anything was frozen. What changes is the mapping: the content shown at the
/// top-left of the *main* region is `contentOffset + frozenSize`, not `contentOffset`. That is the
/// one line everything else here follows from, and it is why the scrolling region can never slide
/// under the frozen band and strand the first unfrozen row.
struct FrozenPaneLayout: Equatable {

    // MARK: - Inputs

    /// How much room the frozen rows and columns take, in points on screen.
    let frozenSize: CGSize
    /// The scrolling area's size — the grid minus its two headers.
    let viewport: CGSize
    let contentOffset: CGPoint

    // MARK: - Init

    /// - Parameters:
    ///   - frozen: how many rows and columns are frozen.
    ///   - geometry: measures them. Nil, or nothing frozen, gives a layout with no panes.
    init(frozen: FrozenPanes, geometry: GridGeometry?, viewport: CGSize, contentOffset: CGPoint) {
        self.viewport = viewport
        self.contentOffset = contentOffset

        guard let geometry, !frozen.isEmpty else {
            frozenSize = .zero
            return
        }
        // Clamped to half the viewport: freezing more than the screen can hold would leave the
        // scrolling region with no room, and a grid that will not scroll reads as broken rather
        // than as frozen.
        frozenSize = CGSize(
            width: min(frozen.columns > 0 ? geometry.x(ofColumn: frozen.columns + 1) : 0,
                       max(0, viewport.width / 2)),
            height: min(frozen.rows > 0 ? geometry.y(ofRow: frozen.rows + 1) : 0,
                        max(0, viewport.height / 2))
        )
    }

    // MARK: - State

    var hasFrozenRows: Bool { frozenSize.height > 0 }
    var hasFrozenColumns: Bool { frozenSize.width > 0 }
    var isEmpty: Bool { !hasFrozenRows && !hasFrozenColumns }

    // MARK: - The main canvas

    /// The main canvas's frame **in the scroll view's content coordinates**, where it lives.
    var mainFrame: CGRect {
        CGRect(origin: CGPoint(x: contentOffset.x + frozenSize.width,
                               y: contentOffset.y + frozenSize.height),
               size: CGSize(width: max(0, viewport.width - frozenSize.width),
                            height: max(0, viewport.height - frozenSize.height)))
    }

    /// The content point drawn at the main canvas's top-left corner.
    var mainContentOrigin: CGPoint {
        CGPoint(x: contentOffset.x + frozenSize.width, y: contentOffset.y + frozenSize.height)
    }

    // MARK: - The panes

    /// Each pane's frame **in viewport coordinates**, and the content point at its top-left corner.
    ///
    /// The panes sit above the scroll view rather than inside it, so the content passes underneath
    /// them — which is what makes them look frozen without the scroll view having to know anything
    /// about it.
    var corner: (frame: CGRect, contentOrigin: CGPoint) {
        (CGRect(origin: .zero, size: frozenSize), .zero)
    }

    var rowBand: (frame: CGRect, contentOrigin: CGPoint) {
        (CGRect(x: frozenSize.width, y: 0,
                width: max(0, viewport.width - frozenSize.width), height: frozenSize.height),
         CGPoint(x: contentOffset.x + frozenSize.width, y: 0))
    }

    var columnBand: (frame: CGRect, contentOrigin: CGPoint) {
        (CGRect(x: 0, y: frozenSize.height,
                width: frozenSize.width, height: max(0, viewport.height - frozenSize.height)),
         CGPoint(x: 0, y: contentOffset.y + frozenSize.height))
    }

    // MARK: - Touches

    /// A viewport point as a content-space point.
    ///
    /// Inside a frozen pane a viewport position *is* a content position — that is what frozen
    /// means — so the scroll offset only applies past the frozen extent. Without this the frozen
    /// cells would draw in one place and be selectable in another.
    func contentPoint(fromViewportPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x < frozenSize.width ? point.x : point.x + contentOffset.x,
                y: point.y < frozenSize.height ? point.y : point.y + contentOffset.y)
    }

    /// Where a content point currently shows, or nil when nothing is showing it — because it has
    /// scrolled away, or because it is behind a frozen pane.
    func viewportPoint(fromContentPoint point: CGPoint) -> CGPoint? {
        let x = point.x < frozenSize.width ? point.x : point.x - contentOffset.x
        let y = point.y < frozenSize.height ? point.y : point.y - contentOffset.y
        guard x >= 0, y >= 0 else { return nil }
        // Past the frozen extent in content space, but landing inside a pane on screen: the scroll
        // has carried it under the frozen band, where it is not visible at all.
        if point.x >= frozenSize.width && x < frozenSize.width { return nil }
        if point.y >= frozenSize.height && y < frozenSize.height { return nil }
        return CGPoint(x: x, y: y)
    }
}
