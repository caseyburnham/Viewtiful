import PDFKit

/// Keeps a display-only vector rendering of the current page. Never modifies the library PDF.
final class PDFDisplayCache {
    private(set) var source: PDFDocument?
    private var inverted = false
    private var invertAnnotations = false
    private var rendered: PDFDocument?
    private var renderedPageIndices: [Int: Int] = [:]
    private var pageAccessOrder: [Int] = []
    private let maxRenderedPages = 16

    func document(source: PDFDocument, pageIndex: Int, inverted: Bool, invertAnnotations: Bool) -> PDFDocument {
        let configurationChanged = self.source !== source || self.inverted != inverted
            || self.invertAnnotations != invertAnnotations
        if configurationChanged {
            rendered = nil
            renderedPageIndices.removeAll()
            pageAccessOrder.removeAll()
        }
        self.source = source
        self.inverted = inverted
        self.invertAnnotations = invertAnnotations

        guard inverted else { return source }
        if rendered == nil { rendered = PDFDocument() }
        guard let rendered else { return source }
        if renderedPageIndices[pageIndex] == nil {
            evictLeastRecentlyUsedPageIfNeeded(from: rendered)
            guard let original = source.page(at: pageIndex),
                  let pageDocument = Self.render(original, invertAnnotations: invertAnnotations),
                  let page = pageDocument.page(at: 0) else { return source }
            let displayIndex = rendered.pageCount
            rendered.insert(page, at: displayIndex)
            renderedPageIndices[pageIndex] = displayIndex
            pageAccessOrder.append(pageIndex)
        } else {
            pageAccessOrder.removeAll { $0 == pageIndex }
            pageAccessOrder.append(pageIndex)
        }
        return rendered.pageCount > 0 ? rendered : source
    }

    private func evictLeastRecentlyUsedPageIfNeeded(from rendered: PDFDocument) {
        guard rendered.pageCount >= maxRenderedPages,
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

    func renderedPageIndex(for sourcePageIndex: Int) -> Int? {
        renderedPageIndices[sourcePageIndex]
    }

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

    static func render(_ original: PDFPage, invertAnnotations: Bool) -> PDFDocument? {
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
        return PDFDocument(data: outputData as Data)
    }
}
