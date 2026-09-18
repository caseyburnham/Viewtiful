import PDFKit
import SwiftUI

enum PDFZoomLevel: Equatable, Sendable {
    case fit
    case factor(Double)
}

#if os(macOS)
struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let invertColors: Bool
    let invertAnnotations: Bool
    let zoom: PDFZoomLevel
    let onPageTurn: (ViewtifulAction) -> Void
    let onGoToPage: () -> Void
    let onFitPage: () -> Void

    func makeNSView(context: Context) -> ShowPDFView {
        let view = ShowPDFView()
        configure(view)
        view.onPageTurn = onPageTurn
        view.onGoToPage = onGoToPage
        view.onFitPage = onFitPage
        update(view, cache: context.coordinator, zoom: zoom)
        return view
    }

    func updateNSView(_ view: ShowPDFView, context: Context) {
        view.onPageTurn = onPageTurn
        view.onGoToPage = onGoToPage
        view.onFitPage = onFitPage
        if context.coordinator.source !== document { view.needsWindowFit = true }
        update(view, cache: context.coordinator, zoom: zoom)
        view.fitWindowIfNeeded()
    }
}

/// PDFKit owns rendering and accessibility. The show viewer owns page navigation.
final class ShowPDFView: PDFView {
    var onPageTurn: ((ViewtifulAction) -> Void)?
    var onGoToPage: (() -> Void)?
    var onFitPage: (() -> Void)?
    var needsWindowFit = true
    private var scrollNavigation = ScrollPageNavigation()

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep PDFKit's internal scroll view from independently changing the page.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "l" {
            onGoToPage?()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "0" {
            onFitPage?()
            return
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 124, 121: onPageTurn?(.nextPage)
        case 123, 116: onPageTurn?(.previousPage)
        case 49: onPageTurn?(event.modifierFlags.contains(.shift) ? .previousPage : .nextPage)
        case 115: onPageTurn?(.firstPage)
        case 119: onPageTurn?(.lastPage)
        case 53: break
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY : event.scrollingDeltaX
        let action = scrollNavigation.action(
            delta: Double(delta),
            precise: event.hasPreciseScrollingDeltas,
            began: event.phase.contains(.began),
            ended: event.phase.contains(.ended) || event.phase.contains(.cancelled),
            momentum: !event.momentumPhase.isEmpty,
            timestamp: event.timestamp
        )
        if let action { onPageTurn?(action) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Wait for SwiftUI to lay out the document viewport before sizing its window.
        DispatchQueue.main.async { [weak self] in self?.fitWindowIfNeeded() }
    }

    override func layout() {
        super.layout()
        if needsWindowFit {
            DispatchQueue.main.async { [weak self] in self?.fitWindowIfNeeded() }
        }
    }

    func fitWindowIfNeeded() {
        guard needsWindowFit, bounds.height > 0, let window,
              let page = currentPage, let screen = window.screen else { return }
        needsWindowFit = false
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed else { return }
        var pageSize = page.bounds(for: .cropBox).size
        if abs(page.rotation) % 180 == 90 { swap(&pageSize.width, &pageSize.height) }
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        let horizontalChrome = max(0, window.frame.width - bounds.width)
        let width = min(screen.visibleFrame.width, max(window.minSize.width, bounds.height * pageSize.width / pageSize.height + horizontalChrome))
        var frame = window.frame
        frame.origin.x += (frame.width - width) / 2
        frame.size.width = width
        frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - width)
        window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}
#else
struct PDFPageView: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let invertColors: Bool
    let invertAnnotations: Bool
    let zoom: PDFZoomLevel
    let onPageTurn: (ViewtifulAction) -> Void
    let onGoToPage: () -> Void
    let onFitPage: () -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        update(view, cache: context.coordinator, zoom: zoom)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        update(view, cache: context.coordinator, zoom: zoom)
    }
}
#endif

extension PDFPageView {
    func makeCoordinator() -> PDFDisplayCache { PDFDisplayCache() }

    func configure(_ view: PDFView) {
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.displaysPageBreaks = false
        // PDFKit's page shadow is drawn outside the page bounds. Against the
        // black display surface it reads as a stray light edge, especially for
        // the display-only inverted document.
        view.pageShadowsEnabled = false
        view.autoScales = true
    }

    func update(_ view: PDFView, cache: PDFDisplayCache, zoom: PDFZoomLevel) {
        #if os(macOS)
        view.backgroundColor = invertColors ? .black : .windowBackgroundColor
        #else
        view.backgroundColor = invertColors ? .black : .systemBackground
        #endif
        let displayed = cache.document(source: document, pageIndex: pageIndex,
                                       inverted: invertColors, invertAnnotations: invertAnnotations)
        if view.document !== displayed { view.document = displayed }
        let index = displayed === document ? pageIndex : cache.renderedPageIndex(for: pageIndex) ?? 0
        if let page = displayed.page(at: index), view.currentPage !== page {
            view.go(to: page)
        }
        applyZoom(to: view, level: zoom)
    }

    private func applyZoom(to view: PDFView, level: PDFZoomLevel) {
        switch level {
        case .fit:
            view.autoScales = true
        case .factor(let factor):
            let fitScale = view.scaleFactorForSizeToFit
            guard fitScale > 0, fitScale.isFinite else { return }
            view.autoScales = false
            view.minScaleFactor = max(0.1, fitScale * 0.25)
            view.maxScaleFactor = max(fitScale * 4, fitScale)
            view.scaleFactor = min(max(fitScale * factor, view.minScaleFactor), view.maxScaleFactor)
        }
    }
}
