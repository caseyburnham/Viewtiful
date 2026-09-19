import PDFKit
import SwiftUI

#if os(macOS)
struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let invertColors: Bool
    let invertAnnotations: Bool
    let onPageTurn: (ViewtifulAction) -> Void
    let onGoToPage: () -> Void

    func makeNSView(context: Context) -> ShowPDFView {
        let view = ShowPDFView()
        configure(view)
        view.onPageTurn = onPageTurn
        view.onGoToPage = onGoToPage
        update(view, cache: context.coordinator)
        return view
    }

    func updateNSView(_ view: ShowPDFView, context: Context) {
        view.onPageTurn = onPageTurn
        view.onGoToPage = onGoToPage
        if context.coordinator.source !== document { view.needsWindowFit = true }
        update(view, cache: context.coordinator)
        view.fitWindowIfNeeded()
        // PDFKit rebuilds its annotation layers for each page it lays out.
        view.scheduleAnnotationLayerScaleFix()
    }
}

/// PDFKit owns rendering and accessibility. The show viewer owns page navigation.
final class ShowPDFView: PDFView {
    var onPageTurn: ((ViewtifulAction) -> Void)?
    var onGoToPage: (() -> Void)?
    var needsWindowFit = true
    private var scrollNavigation = ScrollPageNavigation()
    private var pendingAnnotationScalePasses = 0

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

    /// PDFKit otherwise insets its content below the titlebar. Clearing that lets the page
    /// scale to the whole window and slide under the toolbar's glass.
    private func disableContentInsets() {
        guard let scrollView = firstScrollView(in: self), scrollView.automaticallyAdjustsContentInsets else { return }
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView { return scrollView }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }

    override func layout() {
        disableContentInsets()
        super.layout()
        if needsWindowFit {
            DispatchQueue.main.async { [weak self] in self?.fitWindowIfNeeded() }
        }
        scheduleAnnotationLayerScaleFix()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleAnnotationLayerScaleFix()
    }

    /// PDFKit gives each page tile a contentsScale of the view's scale times the
    /// screen's backing scale, but builds a layer per annotation and leaves those
    /// at 1.0. Ink and shape markup is then rasterized at a fifth of the page's
    /// resolution and upscaled, so it looks blocky next to crisp page text.
    ///
    /// Those layers are built inside PDFKit's own transaction a frame or two
    /// after the page is laid out, so there is no view callback that lands once
    /// they exist. Sweep for them over the next few frames instead, and stop as
    /// soon as a sweep has corrected some and a couple of passes have settled.
    func scheduleAnnotationLayerScaleFix() {
        let wasIdle = pendingAnnotationScalePasses == 0
        pendingAnnotationScalePasses = 30
        if wasIdle { runAnnotationScalePass() }
    }

    private func runAnnotationScalePass() {
        guard pendingAnnotationScalePasses > 0 else { return }
        pendingAnnotationScalePasses -= 1
        if matchAnnotationLayerScale() > 0 {
            pendingAnnotationScalePasses = min(pendingAnnotationScalePasses, 2)
        }
        guard pendingAnnotationScalePasses > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.runAnnotationScalePass()
        }
    }

    /// Returns how many layers needed correcting, so the sweep knows when the
    /// page's annotation layers have shown up.
    @discardableResult
    private func matchAnnotationLayerScale() -> Int {
        guard let window, let root = layer else { return 0 }
        let scale = scaleFactor * window.backingScaleFactor
        guard scale > 0, scale.isFinite else { return 0 }
        return applyAnnotationScale(scale, to: root, insideAnnotation: false)
    }

    private func applyAnnotationScale(_ scale: CGFloat, to layer: CALayer, insideAnnotation: Bool) -> Int {
        var corrected = 0
        let isAnnotation = insideAnnotation
            || String(describing: type(of: layer)).contains("Annotation")
        if isAnnotation, layer.contentsScale != scale {
            layer.contentsScale = scale
            layer.setNeedsDisplay()
            corrected += 1
        }
        for sublayer in layer.sublayers ?? [] {
            corrected += applyAnnotationScale(scale, to: sublayer, insideAnnotation: isAnnotation)
        }
        return corrected
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
    let onPageTurn: (ViewtifulAction) -> Void
    let onGoToPage: () -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        update(view, cache: context.coordinator)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        update(view, cache: context.coordinator)
    }
}
#endif

extension PDFPageView {
    func makeCoordinator() -> PDFDisplayCache { PDFDisplayCache() }

    func configure(_ view: PDFView) {
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.displaysPageBreaks = false
        view.autoScales = true
    }

    func update(_ view: PDFView, cache: PDFDisplayCache) {
        view.pageShadowsEnabled = false
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
        // The page always scales to the window; there is no manual zoom to preserve.
        view.autoScales = true
    }
}
