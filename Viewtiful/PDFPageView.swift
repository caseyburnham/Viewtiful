import PDFKit
import SwiftUI

#if os(macOS)
struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        makePDFView()
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        update(pdfView)
    }

    private func makePDFView() -> PDFView {
        configuredPDFView()
    }

    private func update(_ pdfView: PDFView) {
        updatePDFView(pdfView)
    }
}
#else
struct PDFPageView: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int

    func makeUIView(context: Context) -> PDFView {
        configuredPDFView()
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        updatePDFView(pdfView)
    }
}
#endif

private extension PDFPageView {
    func configuredPDFView() -> PDFView {
        let pdfView = PDFView()
        pdfView.backgroundColor = .black
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.displaysPageBreaks = false
        pdfView.autoScales = true
        pdfView.document = document
        if let page = document.page(at: pageIndex) {
            pdfView.go(to: page)
        }
        return pdfView
    }

    func updatePDFView(_ pdfView: PDFView) {
        if pdfView.document !== document {
            pdfView.document = document
        }

        guard
            let requestedPage = document.page(at: pageIndex),
            pdfView.currentPage !== requestedPage
        else {
            return
        }

        pdfView.go(to: requestedPage)
        pdfView.autoScales = true
    }
}
