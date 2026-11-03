import UIKit
import NeutrinoCore

// MARK: - SheetPreviewer

/// Keeps the workbook's Drive preview — the picture in the Drive grid — showing its first page:
/// the top-left corner of the first sheet, about what a printed page would hold.
///
/// Drawn by the same ``GridCanvasView`` the editor uses, positioned at A1 whatever the user has
/// scrolled to. *When* it is redrawn is ``DocumentPreviewGate``'s, the same rule the web editor
/// follows: on load only when the file has no preview, and after a save only when a cell, a width
/// or a height on that page changed.
@MainActor
final class SheetPreviewer {

    /// Page one — the same 20 × 8 corner the web editor draws.
    static let rows = 20
    static let columns = 8

    private let gate: DocumentPreviewGate
    /// The sheet the next render draws: the one the latest signature was taken from.
    private var sheet: SheetData?

    init(fileID: String, contentService: SheetContentService) {
        var render: DocumentPreviewGate.Render = { nil }
        gate = DocumentPreviewGate(
            render: { await render() },
            upload: { [contentService] jpeg in try await contentService.setPreview(jpeg, for: fileID) }
        )
        render = { [weak self] in await self?.renderPageOne() }
    }

    /// The workbook is on screen: records page one, or draws it if the file has no preview.
    /// Skipped for a reader, whose upload the server would refuse.
    func loaded(_ file: SheetFile, hasPreview: Bool, canEdit: Bool) {
        guard canEdit || hasPreview else { return }
        sheet = file.sheets.first
        let signature = Self.signature(of: sheet)
        Task { await gate.loaded(signature: signature, hasPreview: hasPreview) }
    }

    /// A save landed: redraws page one if it changed.
    func saved(_ file: SheetFile, hasPreview: Bool) {
        sheet = file.sheets.first
        let signature = Self.signature(of: sheet)
        Task { await gate.saved(signature: signature, hasPreview: hasPreview) }
    }

    // MARK: - Signature

    /// The cells on page one, in address order, plus the widths and heights that size it. Equal
    /// whenever page one would draw the same, so an edit at row 500 redraws nothing.
    static func signature(of sheet: SheetData?) -> String {
        guard let sheet else { return "" }
        let cells = sheet.cells.values
            .filter { cell in
                guard let address = CellAddress(cell.id) else { return false }
                return address.column <= columns && address.row <= rows
            }
            .sorted { $0.id < $1.id }
        let widths = (0..<columns).map { sheet.colWidths?[String($0)] }
        let heights = (0..<rows).map { sheet.rowHeights?[String($0)] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(PageOne(cells: cells, widths: widths, heights: heights))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private struct PageOne: Encodable {
        let cells: [SavedCell]
        let widths: [Double?]
        let heights: [Double?]
    }

    // MARK: - Rendering

    private func renderPageOne() -> Data? {
        let geometry = GridGeometry(sheet: sheet, metrics: GridMetrics())
        let corner = geometry.rect(for: CellAddress(column: Self.columns + 1, row: Self.rows + 1)).origin
        let bounds = CGRect(origin: .zero, size: CGSize(width: corner.x, height: corner.y))
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let canvas = GridCanvasView(frame: bounds)
        canvas.model = GridRenderModel(sheet: sheet, geometry: geometry)
        canvas.contentOrigin = .zero

        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = min(1, DriveThumbnail.maxEdge / max(bounds.width, bounds.height))
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            // Paper is light, as the print path has it: the grid's dynamic colours would otherwise
            // draw white text on black from a phone in Dark Mode.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                UIColor.white.setFill()
                context.fill(bounds)
                canvas.draw(bounds)
            }
        }
        return image.jpegData(compressionQuality: 0.82)
    }
}
