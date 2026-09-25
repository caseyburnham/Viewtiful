import PDFKit

/// Prepares the pages on either side of the current one before they are turned to.
/// Never modifies the library PDF.
@MainActor
final class PageWarmer {
    /// A script is read a page at a time in both directions, so one each way covers
    /// nearly every turn.
    private static let radius = 1

    /// Serial, so a run of quick page turns queues its work rather than piling it up.
    private static let queue = DispatchQueue(
        label: "Viewtiful.PageWarmer",
        qos: .userInitiated
    )

    /// The show being warmed. Another one arriving means a document was opened.
    private(set) var source: PDFDocument?
    private var warmedPages: Set<Int> = []

    func warm(around pageIndex: Int, in document: PDFDocument) {
        if source !== document {
            source = document
            warmedPages.removeAll()
        }
        for offset in 1...Self.radius {
            for neighbour in [pageIndex - offset, pageIndex + offset]
            where (0..<document.pageCount).contains(neighbour) && !warmedPages.contains(neighbour) {
                guard let reference = document.page(at: neighbour)?.pageRef else { continue }
                warmedPages.insert(neighbour)
                let carried = Unsafely(reference)
                Self.queue.async { Self.parse(carried.value) }
            }
        }
    }

    /// Plays the page's content stream into a single pixel. Every operator runs, so
    /// the page's fonts and resources are loaded and cached on the page PDFKit will
    /// draw from, but there is next to nothing to rasterize. The pixel is discarded.
    private nonisolated static func parse(_ page: CGPDFPage) {
        let pixel = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        // Scaled down whole rather than clipped, so nothing is culled as off-canvas.
        let transform = page.getDrawingTransform(.cropBox, rect: pixel, rotate: 0,
                                                 preserveAspectRatio: false)
        context.concatenate(transform)
        context.drawPDFPage(page)
    }
}

/// Core Graphics PDF pages carry no `Sendable` conformance, but PDFKit itself draws
/// them off the main thread while a document is on screen. This carries one to the
/// warming queue, where it is only ever read.
private struct Unsafely<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
