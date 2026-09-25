import PDFKit

/// Draws markup the way the viewer needs it to read, which is not always the way the
/// PDF authored it. The context is expected to be the one PDFKit hands a page to
/// draw into, before the page's box origin and rotation are applied.
///
/// Nonisolated because pages draw on PDFKit's tile threads; nothing here touches
/// shared state beyond the context it is handed.
nonisolated enum PDFAnnotationDrawing {
    /// Markup exactly as the PDF describes it, for a page shown in its own colors.
    static func drawAsAuthored(_ annotations: [PDFAnnotation], box: PDFDisplayBox, in context: CGContext) {
        for annotation in annotations where annotation.shouldDisplay {
            context.saveGState()
            annotation.draw(with: box, in: context)
            context.restoreGState()
        }
    }

    /// Markup for an inverted page, where authored highlights would hide the text.
    static func draw(_ annotations: [PDFAnnotation], box: PDFDisplayBox, in context: CGContext) {
        for annotation in annotations where annotation.shouldDisplay {
            context.saveGState()
            if annotation.type == "Highlight" {
                // `annotation.draw` places itself for the page's box; a highlight
                // rebuilt from its quads is in page coordinates and has to be placed.
                annotation.page?.transform(context, for: box)
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
    /// translucent fill so the inverted page remains readable.
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
