import PDFKit

/// Keeps a display-only vector rendering of the current page, and prepares the pages
/// on either side of it before they are asked for. Never modifies the library PDF.
@MainActor
final class PDFDisplayCache {
    /// A document, and the page within it the view should be showing.
    struct DisplayTarget {
        let document: PDFDocument
        let pageIndex: Int
    }

    /// How far either side of the current page to prepare. A script is read a page at
    /// a time in both directions, so one each way covers nearly every turn.
    private static let prefetchRadius = 1
    /// Generous because prefetching fills this faster than navigation alone did, and
    /// dropping a page renumbers the document the view is currently displaying.
    private static let maxRenderedPages = 64
    /// Large enough that PDFKit parses the page's content stream and fonts for real,
    /// which is the slow half of drawing it, without paying for a full rasterization.
    private static let warmupSize = CGSize(width: 512, height: 512)

    /// PDFKit renders its own page tiles off the main thread while a document is on
    /// screen, so reading a page from this queue is an access it already makes itself.
    /// Serial, so a run of quick page turns queues its work rather than piling it up.
    private static let renderQueue = DispatchQueue(
        label: "Viewtiful.PDFDisplayCache.render",
        qos: .userInitiated
    )

    /// Delivers a page that was not ready when the view asked for it. The view keeps
    /// the page it already has until this lands, so a turn is never shown a blank.
    var onPageReady: ((PDFDocument, Int) -> Void)?

    private(set) var source: PDFDocument?
    private var inverted = false
    private var invertAnnotations = false
    private var rendered: PDFDocument?
    private var renderedPageIndices: [Int: Int] = [:]
    private var pageAccessOrder: [Int] = []
    private var pagesInFlight: Set<Int> = []
    private var warmedPages: Set<Int> = []
    /// The page the view last asked for. A render that finishes after the reader has
    /// moved on is kept, but not shown: displaying it would turn the page backwards.
    private var requestedPageIndex: Int?
    /// Bumped whenever the document or the color treatment changes, so work that was
    /// already in the air at that moment is discarded rather than applied.
    private var generation = 0

    /// The page to display right now, or `nil` if an inverted copy of it is still
    /// being built. A `nil` answer is a request to leave the view alone and wait for
    /// `onPageReady`, which is what keeps a turn from flashing through an empty view.
    func target(source: PDFDocument, pageIndex: Int, inverted: Bool,
                invertAnnotations: Bool) -> DisplayTarget? {
        resetIfConfigurationChanged(source: source, inverted: inverted,
                                    invertAnnotations: invertAnnotations)
        requestedPageIndex = pageIndex
        defer { prefetch(around: pageIndex) }

        guard inverted else { return DisplayTarget(document: source, pageIndex: pageIndex) }

        if let displayIndex = touch(pageIndex) {
            return rendered.map { DisplayTarget(document: $0, pageIndex: displayIndex) }
        }
        // Nothing is on screen yet, so there is no outgoing page to hold. Build this
        // one now rather than open the document to an empty window.
        if renderedPageIndices.isEmpty,
           let displayIndex = insert(renderedData(for: pageIndex), for: pageIndex) {
            return rendered.map { DisplayTarget(document: $0, pageIndex: displayIndex) }
        }
        requestRender(of: pageIndex)
        return nil
    }

    private func resetIfConfigurationChanged(source: PDFDocument, inverted: Bool,
                                             invertAnnotations: Bool) {
        let changed = self.source !== source || self.inverted != inverted
            || self.invertAnnotations != invertAnnotations
        if changed {
            generation &+= 1
            rendered = nil
            renderedPageIndices.removeAll()
            pageAccessOrder.removeAll()
            pagesInFlight.removeAll()
            warmedPages.removeAll()
        }
        self.source = source
        self.inverted = inverted
        self.invertAnnotations = invertAnnotations
        if inverted, rendered == nil { rendered = PDFDocument() }
    }

    /// Marks a rendered page as the most recently used and returns where it sits.
    private func touch(_ pageIndex: Int) -> Int? {
        guard let displayIndex = renderedPageIndices[pageIndex] else { return nil }
        pageAccessOrder.removeAll { $0 == pageIndex }
        pageAccessOrder.append(pageIndex)
        return displayIndex
    }

    // MARK: - Preparing pages ahead of the turn

    private func prefetch(around pageIndex: Int) {
        guard let source, Self.prefetchRadius > 0 else { return }
        for offset in 1...Self.prefetchRadius {
            for neighbour in [pageIndex - offset, pageIndex + offset]
            where (0..<source.pageCount).contains(neighbour) {
                if inverted {
                    requestRender(of: neighbour)
                } else {
                    warm(neighbour, in: source)
                }
            }
        }
    }

    /// Draws a page PDFKit has not been asked for yet and throws the result away. The
    /// image is not the point: parsing the page is, and that work is cached on the
    /// page itself, so the view's first real draw of it no longer starts from cold.
    private func warm(_ pageIndex: Int, in document: PDFDocument) {
        guard !warmedPages.contains(pageIndex),
              let page = document.page(at: pageIndex) else { return }
        warmedPages.insert(pageIndex)
        let carried = Unsafely(page)
        Self.renderQueue.async {
            _ = carried.value.thumbnail(of: Self.warmupSize, for: .cropBox)
        }
    }

    private func requestRender(of pageIndex: Int) {
        guard inverted, renderedPageIndices[pageIndex] == nil,
              !pagesInFlight.contains(pageIndex),
              let original = source?.page(at: pageIndex) else { return }
        pagesInFlight.insert(pageIndex)

        let page = Unsafely(original)
        let invertAnnotations = self.invertAnnotations
        let generation = self.generation
        Self.renderQueue.async {
            let data = Self.render(page.value, invertAnnotations: invertAnnotations)
            Task { @MainActor [weak self] in
                self?.finishRender(of: pageIndex, data: data, generation: generation)
            }
        }
    }

    private func finishRender(of pageIndex: Int, data: Data?, generation: Int) {
        guard generation == self.generation else { return }
        pagesInFlight.remove(pageIndex)
        guard let displayIndex = insert(data, for: pageIndex), let rendered else { return }
        // A page prepared ahead of time is kept but not shown, and one that finished
        // after the reader moved past it would turn the page backwards.
        guard pageIndex == requestedPageIndex else { return }
        onPageReady?(rendered, displayIndex)
    }

    /// Renders a page on the calling thread. Used only for the first page of a
    /// document, where there is nothing on screen to wait behind.
    private func renderedData(for pageIndex: Int) -> Data? {
        guard let original = source?.page(at: pageIndex) else { return nil }
        return Self.render(original, invertAnnotations: invertAnnotations)
    }

    /// Adds a finished copy to the display document and returns where it landed.
    private func insert(_ data: Data?, for pageIndex: Int) -> Int? {
        guard let rendered else { return nil }
        if let existing = renderedPageIndices[pageIndex] { return existing }

        let page: PDFPage
        if let data, let copy = PDFDocument(data: data), let rendering = copy.page(at: 0) {
            page = rendering
        } else if let fallback = source?.page(at: pageIndex)?.copy() as? PDFPage {
            // A page that will not render inverted still has to appear, and it has to
            // appear in this document: handing the view back the source document for
            // one bad page would swap the whole show out and back on every turn.
            page = fallback
        } else {
            return nil
        }

        evictLeastRecentlyUsedPageIfNeeded(from: rendered)
        let displayIndex = rendered.pageCount
        rendered.insert(page, at: displayIndex)
        renderedPageIndices[pageIndex] = displayIndex
        pageAccessOrder.append(pageIndex)
        return displayIndex
    }

    private func evictLeastRecentlyUsedPageIfNeeded(from rendered: PDFDocument) {
        guard rendered.pageCount >= Self.maxRenderedPages,
              let evictedPageIndex = pageAccessOrder.first,
              let evictedDisplayIndex = renderedPageIndices.removeValue(forKey: evictedPageIndex) else { return }

        pageAccessOrder.removeFirst()
        rendered.removePage(at: evictedDisplayIndex)
        let affectedPages = renderedPageIndices.compactMap { pageIndex, displayIndex in
            displayIndex > evictedDisplayIndex ? pageIndex : nil
        }
        for pageIndex in affectedPages {
            renderedPageIndices[pageIndex, default: 0] -= 1
        }
    }

    // MARK: - Drawing an inverted copy

    private static func drawAnnotations(_ annotations: [PDFAnnotation], in context: CGContext) {
        for annotation in annotations where annotation.shouldDisplay {
            context.saveGState()
            if annotation.type == "Highlight" {
                drawHighlight(annotation, in: context)
            } else {
                annotation.draw(with: .cropBox, in: context)
            }
            context.restoreGState()
        }
    }

    private static func drawHighlight(_ annotation: PDFAnnotation, in context: CGContext) {
        // PDF highlight appearance streams commonly use an opaque Multiply
        // fill. That is legible on a white page, but can hide the inverted
        // page's light text. Rebuild the markup from its quads with a normal,
        // translucent fill so the display copy remains readable.
        context.setBlendMode(.normal)
        context.setAlpha(0.35)
        context.setFillColor(annotation.color.cgColor)

        let points = annotation.quadrilateralPoints ?? []
        if points.count >= 4 {
            for quad in stride(from: 0, to: points.count - 3, by: 4) {
                let path = CGMutablePath()
                func point(at index: Int) -> CGPoint {
                    var value = CGPoint.zero
                    points[index].getValue(&value)
                    return CGPoint(x: annotation.bounds.minX + value.x, y: annotation.bounds.minY + value.y)
                }
                path.move(to: point(at: quad))
                path.addLine(to: point(at: quad + 1))
                path.addLine(to: point(at: quad + 3))
                path.addLine(to: point(at: quad + 2))
                path.closeSubpath()
                context.addPath(path)
                context.fillPath()
            }
        } else {
            context.fill(annotation.bounds)
        }
    }

    /// Returns a one-page PDF of the inverted page. The result is data rather than a
    /// document so it can cross back from the render queue as a value.
    static func render(_ original: PDFPage, invertAnnotations: Bool) -> Data? {
        guard let data = original.dataRepresentation,
              let copy = PDFDocument(data: data), let page = copy.page(at: 0) else { return nil }
        let annotations = page.annotations
        // PDFKit can include annotation appearances in pageRef; remove them from
        // an independent display copy before requesting the underlying page.
        for annotation in annotations { page.removeAnnotation(annotation) }
        guard let reference = page.pageRef else { return nil }
        let crop = original.bounds(for: .cropBox)
        var size = crop.size
        if abs(original.rotation) % 180 == 90 { swap(&size.width, &size.height) }
        guard size.width > 0, size.height > 0 else { return nil }
        var bounds = CGRect(origin: .zero, size: size)
        let outputData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        let transform = reference.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true)
        context.saveGState()
        context.concatenate(transform)
        context.drawPDFPage(reference)
        if invertAnnotations && original.displaysAnnotations { drawAnnotations(annotations, in: context) }
        context.restoreGState()
        context.saveGState()
        context.setBlendMode(.difference)
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.restoreGState()
        if !invertAnnotations && original.displaysAnnotations {
            context.saveGState()
            context.concatenate(transform)
            drawAnnotations(annotations, in: context)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        return outputData as Data
    }
}

/// PDFKit's types carry no `Sendable` conformance, but PDFKit itself draws pages off
/// the main thread while a document is on screen. This carries one to the render
/// queue, where it is only ever read, and only from that one queue at a time.
private struct Unsafely<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
