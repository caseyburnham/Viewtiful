import PDFKit
import Synchronization

/// How the viewer wants a show's pages drawn.
nonisolated struct PageAppearance: Equatable, Sendable {
    var inverted = false
    var invertAnnotations = false
}

/// A show document whose pages draw themselves in the viewer's colors. Nothing is
/// copied or re-rendered to change them: PDFKit keeps drawing the one document it
/// was given, and each page applies the appearance as it is drawn.
nonisolated final class ShowDocument: PDFDocument {
    /// PDFKit draws page tiles on its own threads, and every one of them reads this.
    private let appearanceState = Mutex(PageAppearance())

    var appearance: PageAppearance {
        get { appearanceState.withLock { $0 } }
        set { appearanceState.withLock { $0 = newValue } }
    }

    override var pageClass: AnyClass { ShowPage.self }
}

/// Draws a page, and its markup, in the document's current appearance.
///
/// Called by PDFKit off the main thread for every tile, so it reads nothing but
/// the page itself and the document's locked appearance.
nonisolated final class ShowPage: PDFPage {
    /// Left to itself, PDFView gives annotations layers of their own and rasterizes
    /// them at 1x, so markup looks blocky beside the page's text. Refusing them here
    /// and drawing them in `draw(with:to:)` instead puts markup in the page's own
    /// tiles, at the page's resolution, where the inversion can decide how they look.
    override var displaysAnnotations: Bool {
        get { false }
        set {}
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let appearance = (document as? ShowDocument)?.appearance ?? PageAppearance()
        let annotations = self.annotations

        guard appearance.inverted else {
            super.draw(with: box, to: context)
            PDFAnnotationDrawing.drawAsAuthored(annotations, box: box, in: context)
            return
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: 1, alpha: 1))

        // Paper first: the difference fill below turns it black, and a tile that
        // arrived transparent would otherwise come out white.
        fillPage(box, in: context)
        drawContent(annotations, box: box, includingAnnotations: appearance.invertAnnotations, in: context)

        // Paper to black, type to white.
        context.setBlendMode(.difference)
        fillPage(box, in: context)

        // Inverting flips hue along with lightness, so red ink would read as cyan.
        // Putting the original's hue and saturation back over the inverted lightness
        // keeps colored marks their own color. Black, white and gray carry no hue,
        // so type and paper are left exactly as the inversion made them.
        context.setBlendMode(.color)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawContent(annotations, box: box, includingAnnotations: appearance.invertAnnotations, in: context)
        context.endTransparencyLayer()

        context.setBlendMode(.normal)
        if !appearance.invertAnnotations {
            PDFAnnotationDrawing.draw(annotations, box: box, in: context)
        }
    }

    /// PDFKit hands pages a context that is not yet in page space: the page's own
    /// drawing and each annotation's apply the box's origin and rotation themselves.
    /// Anything drawn here in page coordinates has to do the same, or it lands
    /// offset by the crop box's origin.
    ///
    /// An antialiased fill that stops exactly at the page's edge only partly covers
    /// the last pixels, and PDFKit's white page backing shows through them as a
    /// light hairline — most visible while a turn slides the page. Overfilling
    /// without antialiasing covers every edge pixel; the tile clips the rest.
    private func fillPage(_ box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        transform(context, for: box)
        context.setShouldAntialias(false)
        context.fill(bounds(for: box).insetBy(dx: -2, dy: -2))
        context.restoreGState()
    }

    private func drawContent(_ annotations: [PDFAnnotation], box: PDFDisplayBox,
                             includingAnnotations: Bool, in context: CGContext) {
        super.draw(with: box, to: context)
        if includingAnnotations {
            PDFAnnotationDrawing.draw(annotations, box: box, in: context)
        }
    }
}
