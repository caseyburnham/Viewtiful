import AppKit
import PDFKit
import Testing
@testable import ViewtifulCore

struct PDFInversionTests {
    @Test func keepsTextVisibleUnderHighlightsWhenPageIsInverted() throws {
        let data = makeHighlightAppearancePDF()

        let unannotated = try #require(PDFDocument(data: data as Data))
        let unannotatedPage = try #require(unannotated.page(at: 0))
        for annotation in unannotatedPage.annotations { unannotatedPage.removeAnnotation(annotation) }
        let baseline = try #require(PDFDisplayCache.render(unannotatedPage, invertAnnotations: false))

        let source = try #require(PDFDocument(data: data as Data))
        let page = try #require(source.page(at: 0))
        let highlight = try #require(page.annotations.first)
        #expect(highlight.type == "Highlight")
        #expect(highlight.hasAppearanceStream)
        let annotated = try #require(PDFDisplayCache.render(page, invertAnnotations: false))

        func pixels(for page: PDFPage) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8,
                                                  bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.drawPDFPage(try #require(page.pageRef))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 240 * 160 * 4))
        }

        let expectedText = try pixels(for: try #require(baseline.page(at: 0)))
        let actualText = try pixels(for: try #require(annotated.page(at: 0)))
        let transform = try #require(page.pageRef).getDrawingTransform(
            .cropBox, rect: CGRect(x: 0, y: 0, width: 240, height: 160), rotate: 0, preserveAspectRatio: true
        )
        let highlightBackground = CGPoint(x: 22, y: 82).applying(transform)
        let backgroundX = Int(highlightBackground.x)
        let backgroundY = 160 - 1 - Int(highlightBackground.y)
        let backgroundOffset = (backgroundY * 240 + backgroundX) * 4
        #expect(actualText[backgroundOffset] > 30 && actualText[backgroundOffset] < 200)
        #expect(actualText[backgroundOffset + 1] > 30 && actualText[backgroundOffset + 1] < 200)
        #expect(actualText[backgroundOffset + 2] < 30)
        var baselineTextPixels = 0
        var visibleTextPixels = 0
        for offset in stride(from: 0, to: expectedText.count, by: 4) {
            let expectedLuminance = Int(expectedText[offset]) + Int(expectedText[offset + 1]) + Int(expectedText[offset + 2])
            guard expectedLuminance > 660 else { continue }
            baselineTextPixels += 1
            let actualLuminance = Int(actualText[offset]) + Int(actualText[offset + 1]) + Int(actualText[offset + 2])
            if actualLuminance > 240 { visibleTextPixels += 1 }
        }

        #expect(baselineTextPixels > 100)
        #expect(visibleTextPixels * 2 > baselineTextPixels)
    }

    @Test func reusesDisplayDocumentAcrossInvertedPages() throws {
        var media = CGRect(x: 0, y: 0, width: 120, height: 160)
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        let writer = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        for _ in 0..<2 {
            writer.beginPDFPage(nil)
            writer.setFillColor(CGColor(gray: 1, alpha: 1))
            writer.fill(media)
            writer.endPDFPage()
        }
        writer.closePDF()
        let source = try #require(PDFDocument(data: data as Data))
        let cache = PDFDisplayCache()

        let first = cache.document(source: source, pageIndex: 0, inverted: true, invertAnnotations: false)
        let firstPageIndex = try #require(cache.renderedPageIndex(for: 0))
        let second = cache.document(source: source, pageIndex: 1, inverted: true, invertAnnotations: false)
        let secondPageIndex = try #require(cache.renderedPageIndex(for: 1))

        #expect(first === second)
        #expect(second.pageCount == 2)
        #expect(firstPageIndex == 0)
        #expect(secondPageIndex == 1)
    }

    @Test func preservesAnnotationsAndSourceAcrossRotations() throws {
        for rotation in [0, 90, 180, 270] {
            var media = CGRect(x: 0, y: 0, width: 120, height: 160)
            let data = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: data))
            let writer = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
            writer.beginPDFPage(nil)
            writer.setFillColor(CGColor(gray: 1, alpha: 1))
            writer.fill(media)
            writer.setFillColor(CGColor(gray: 0, alpha: 1))
            writer.fill(CGRect(x: 30, y: 40, width: 20, height: 20))
            writer.endPDFPage()
            writer.closePDF()
            let source = try #require(PDFDocument(data: data as Data))
            let page = try #require(source.page(at: 0))
            page.setBounds(CGRect(x: 10, y: 20, width: 100, height: 120), for: .cropBox)
            page.rotation = rotation
            let annotation = PDFAnnotation(bounds: CGRect(x: 60, y: 80, width: 20, height: 20), forType: .square, withProperties: nil)
            annotation.color = .red
            annotation.interiorColor = .red
            page.addAnnotation(annotation)
            let highlight = PDFAnnotation(bounds: CGRect(x: 25, y: 110, width: 25, height: 15), forType: .highlight, withProperties: nil)
            highlight.color = .yellow
            page.addAnnotation(highlight)
            let before = page.bounds(for: .cropBox)
            for invertAnnotations in [false, true] {
                let result = try #require(PDFDisplayCache.render(page, invertAnnotations: invertAnnotations))
                let output = try #require(result.page(at: 0))
                let size = output.bounds(for: .mediaBox).size
                let width = Int(size.width), height = Int(size.height)
                let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.drawPDFPage(try #require(output.pageRef))
                let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
                var red = 0, cyan = 0, white = 0, black = 0, yellow = 0, blue = 0
                for i in stride(from: 0, to: width * height * 4, by: 4) {
                    let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                    if r > 50 && g > 50 && b < 40 { yellow += 1 }
                    if r < 40 && g < 40 && b > 50 { blue += 1 }
                    if r > 240 && g < 15 && b < 15 { red += 1 }
                    if r < 15 && g > 240 && b > 240 { cyan += 1 }
                    if r > 240 && g > 240 && b > 240 { white += 1 }
                    if r < 15 && g < 15 && b < 15 { black += 1 }
                }
                #expect(invertAnnotations ? cyan > 300 && red == 0 : red > 300 && cyan == 0)
                let transform = try #require(page.pageRef).getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
                let center = CGPoint(x: 70, y: 90).applying(transform)
                let offset = ((height - 1 - Int(center.y)) * width + Int(center.x)) * 4
                #expect(pixels[offset] == (invertAnnotations ? 0 : 255))
                #expect(pixels[offset + 1] == (invertAnnotations ? 255 : 0))
                #expect(invertAnnotations ? blue > 100 : yellow > 100)
                #expect(white > 300)
                #expect(black > 9000)
            }
            #expect(page.displaysAnnotations)
            #expect(annotation.color == .red)
            #expect(page.bounds(for: .cropBox) == before)
            #expect(page.rotation == rotation)
            #expect(page.annotations.count == 2)
            #expect(page.annotations.first === annotation)
        }
    }
}

private func makeHighlightAppearancePDF() -> Data {
    let pageContent = """
    q
    1 1 1 rg
    0 0 240 160 re f
    0 0 0 rg
    28 72 7 22 re f
    35 72 5 4 re f
    35 81 4 4 re f
    42 72 7 22 re f
    49 72 5 4 re f
    49 81 4 4 re f
    56 72 7 22 re f
    63 72 5 4 re f
    63 81 4 4 re f
    70 72 7 22 re f
    77 72 5 4 re f
    77 81 4 4 re f
    84 72 7 22 re f
    91 72 5 4 re f
    91 81 4 4 re f
    98 72 7 22 re f
    105 72 5 4 re f
    105 81 4 4 re f
    112 72 7 22 re f
    119 72 5 4 re f
    119 81 4 4 re f
    126 72 7 22 re f
    133 72 5 4 re f
    133 81 4 4 re f
    140 72 7 22 re f
    147 72 5 4 re f
    147 81 4 4 re f
    154 72 7 22 re f
    161 72 5 4 re f
    161 81 4 4 re f
    168 72 7 22 re f
    175 72 5 4 re f
    175 81 4 4 re f
    182 72 7 22 re f
    189 72 5 4 re f
    189 81 4 4 re f
    196 72 7 22 re f
    203 72 5 4 re f
    203 81 4 4 re f
    Q
    """
    let appearance = """
    q
    /GS1 gs
    1 1 0 rg
    0 0 205 40 re f
    Q
    """
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] /Contents 4 0 R /Annots [6 0 R] /Resources << /ProcSet [/PDF] >> >>",
        "<< /Length \(pageContent.utf8.count) >>\nstream\n\(pageContent)endstream",
        "<< /Type /XObject /Subtype /Form /FormType 1 /BBox [0 0 205 40] /Resources 7 0 R /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream",
        "<< /Type /Annot /Subtype /Highlight /Rect [18 62 223 102] /C [1 1 0] /QuadPoints [18 102 223 102 18 62 223 62] /AP << /N 5 0 R >> >>",
        "<< /ProcSet [/PDF] /ExtGState << /GS1 8 0 R >> >>",
        "<< /Type /ExtGState /BM /Multiply >>"
    ]

    var data = Data("%PDF-1.4\n".utf8)
    var offsets = [0]
    func append(_ string: String) { data.append(contentsOf: string.utf8) }
    for (index, object) in objects.enumerated() {
        offsets.append(data.count)
        append("\(index + 1) 0 obj\n\(object)\nendobj\n")
    }
    let xrefOffset = data.count
    append("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n")
    for offset in offsets.dropFirst() { append(String(format: "%010d 00000 n \n", offset)) }
    append("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n")
    return data
}
