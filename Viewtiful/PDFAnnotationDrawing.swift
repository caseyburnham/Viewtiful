import PDFKit

/// Draws markup the way the viewer needs it to read, which is not always the way the
/// PDF authored it. The context is expected to be in the page's own coordinates.
///
/// Nonisolated because the display cache draws inverted copies on its render queue;
/// nothing here touches shared state beyond the context it is handed.
nonisolated enum PDFAnnotationDrawing {
    static func draw(_ annotations: [PDFAnnotation], box: PDFDisplayBox, in context: CGContext) {
        for annotation in annotations where annotation.shouldDisplay {
            context.saveGState()
            if annotation.type == "Highlight" {
                drawHighlight(annotation, in: context)
            } else {
                annotation.draw(with: box, in: context)
            }
            context.restoreGState()
        }
    }

    /// PDF highlight appearance streams commonly use an opaque Multiply
    /// fill. That is legible on a white page, but can hide the inverted
    /// page's light text. Rebuild the markup from its quads with a normal,
    /// translucent fill so the display copy remains readable.
    private static func drawHighlight(_ annotation: PDFAnnotation, in context: CGContext) {
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
}
