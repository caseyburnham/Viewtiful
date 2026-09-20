import PDFKit
import SwiftUI

#if os(macOS)
struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let invertColors: Bool
    let invertAnnotations: Bool
    let reduceMotion: Bool
    let onPageTurn: (ViewtifulAction) -> Void
    let onGoToPage: () -> Void

    func makeNSView(context: Context) -> ShowPDFView {
        let view = ShowPDFView()
        configure(view)
        view.onPageTurn = onPageTurn
        view.onGoToPage = onGoToPage
        update(view, cache: context.coordinator, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: ShowPDFView, context: Context) {
        view.onPageTurn = onPageTurn
        view.onGoToPage = onGoToPage
        if context.coordinator.source !== document { view.needsWindowFit = true }
        let previousPage = view.currentPage
        update(view, cache: context.coordinator, reduceMotion: reduceMotion)
        view.fitWindowIfNeeded()
        // PDFKit rebuilds its annotation layers for each page it lays out, so only a
        // page that actually changed needs the sweep. Updates that leave the page
        // alone — a toolbar fading in, say — would otherwise redraw it for nothing.
        if view.currentPage !== previousPage {
            view.scheduleAnnotationLayerScaleFix()
        }
    }
}

/// PDFKit owns rendering and accessibility. The show viewer owns page navigation.
final class ShowPDFView: PDFView, PDFViewDelegate {
    private static let pageTransitionRevealDelay = 0.08
    private static let pageTransitionFadeDuration = 0.18

    var onPageTurn: ((ViewtifulAction) -> Void)?
    var onGoToPage: (() -> Void)?
    var needsWindowFit = true
    private var scrollNavigation = ScrollPageNavigation()
    private var pendingAnnotationScalePasses = 0
    private var pageTransitionOverlay: PageTransitionImageView?
    private var pageTransitionWorkItem: DispatchWorkItem?
    private var pageTransitionGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

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

    // MARK: - Zoom

    /// Zooming is off: the page is always drawn at the largest scale that fits the
    /// view. Every scale change — pinch, smart magnify, the zoom actions, and
    /// PDFKit's own autoscaling — passes through here, so answering with the
    /// size-to-fit scale keeps the page fitted and refuses everything else.
    func pdfViewWillChangeScaleFactor(_ sender: PDFView, toScale scale: CGFloat) -> CGFloat {
        let fit = sender.scaleFactorForSizeToFit
        return fit > 0 && fit.isFinite ? fit : scale
    }

    override func magnify(with event: NSEvent) {}

    override func smartMagnify(with event: NSEvent) {}

    override var canZoomIn: Bool { false }

    override var canZoomOut: Bool { false }

    override func zoomIn(_ sender: Any?) {}

    override func zoomOut(_ sender: Any?) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Wait for SwiftUI to lay out the document viewport before sizing its window.
        DispatchQueue.main.async { [weak self] in self?.fitWindowIfNeeded() }
    }

    /// AppKit hands every view under the window's full-size titlebar a top safe area
    /// inset, and PDFKit lays its page out inside it. The toolbar floats over the page
    /// here rather than reserving space, so the whole view is fair game.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    /// PDFKit also insets its own scroll view below the titlebar, and re-applies that
    /// while laying out, so the insets are cleared on every pass rather than once.
    private func clearContentInsets() {
        guard let scrollView = firstScrollView(in: self) else { return }
        if scrollView.automaticallyAdjustsContentInsets {
            scrollView.automaticallyAdjustsContentInsets = false
        }
        // Reassigning unconditionally would invalidate layout on every pass.
        let insets = scrollView.contentInsets
        if insets.top != 0 || insets.bottom != 0 || insets.left != 0 || insets.right != 0 {
            scrollView.contentInsets = NSEdgeInsets()
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView { return scrollView }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }

    override func layout() {
        clearContentInsets()
        super.layout()
        // PDFKit reserves the titlebar's space again as it lays the page out.
        clearContentInsets()
        pageTransitionOverlay?.frame = bounds
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

    /// PDFKit paints the new page progressively: a coarse tile can be visible for
    /// a frame before the final tile arrives. Keep the already-sharp outgoing page
    /// over that handoff, then reveal the new page with a short native fade.
    func showPage(_ page: PDFPage, animated: Bool) {
        pageTransitionGeneration &+= 1
        let generation = pageTransitionGeneration
        pageTransitionWorkItem?.cancel()
        pageTransitionWorkItem = nil

        if animated, let snapshot = pageTransitionSnapshot() {
            let overlay = pageTransitionOverlay ?? PageTransitionImageView(frame: bounds)
            overlay.image = snapshot
            overlay.frame = bounds
            overlay.alphaValue = 1
            overlay.isHidden = false
            addSubview(overlay, positioned: .above, relativeTo: nil)
            pageTransitionOverlay = overlay
        } else {
            clearPageTransitionOverlay()
        }

        go(to: page)

        guard animated, let overlay = pageTransitionOverlay else { return }
        let workItem = DispatchWorkItem { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.pageTransitionFadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                overlay.animator().alphaValue = 0
            } completionHandler: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                if self.pageTransitionGeneration == generation,
                   self.pageTransitionOverlay === overlay {
                    self.clearPageTransitionOverlay()
                }
            }
        }
        pageTransitionWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.pageTransitionRevealDelay,
            execute: workItem
        )
    }

    private func pageTransitionSnapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        pageTransitionOverlay?.isHidden = true
        displayIfNeeded()
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private func clearPageTransitionOverlay() {
        pageTransitionOverlay?.removeFromSuperview()
        pageTransitionOverlay?.image = nil
        pageTransitionOverlay = nil
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

    deinit {
        pageTransitionWorkItem?.cancel()
    }
}

private final class PageTransitionImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#else
struct PDFPageView: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let invertColors: Bool
    let invertAnnotations: Bool
    let reduceMotion: Bool
    let onPageTurn: (ViewtifulAction) -> Void
    let onGoToPage: () -> Void

    func makeUIView(context: Context) -> FitPDFView {
        let view = FitPDFView()
        configure(view)
        update(view, cache: context.coordinator, reduceMotion: reduceMotion)
        return view
    }

    func updateUIView(_ view: FitPDFView, context: Context) {
        update(view, cache: context.coordinator, reduceMotion: reduceMotion)
    }
}

/// Zooming is off: the page is always drawn at the largest scale that fits the view.
final class FitPDFView: PDFView, PDFViewDelegate {
    private static let pageTransitionRevealDelay = 0.08
    private static let pageTransitionFadeDuration = 0.18

    private var pageTransitionOverlay: UIImageView?
    private var pageTransitionWorkItem: DispatchWorkItem?
    private var pageTransitionGeneration = 0

    /// Walk from PDFKit's public document view to its containing scroll view.
    var contentScrollView: UIScrollView? {
        var ancestor = documentView?.superview
        while let view = ancestor, view !== self {
            if let scrollView = view as? UIScrollView { return scrollView }
            ancestor = view.superview
        }
        return nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    /// UIKit hands the view the status and navigation bars' inset, and PDFKit fits the
    /// page inside whatever is left. The bar floats over the page rather than reserving
    /// space, so the whole view is fair game and the page fills it.
    override var safeAreaInsets: UIEdgeInsets { .zero }

    override func layoutSubviews() {
        // The native toolbar overlays the page; its safe area must never alter fit.
        preventToolbarInsets()
        super.layoutSubviews()
        preventToolbarInsets()
        pageTransitionOverlay?.frame = bounds
        // PDFKit rebuilds its scrolling machinery as pages lay out, so sweep each pass.
        disableZoomGestures(in: self)
    }

    private func preventToolbarInsets() {
        guard let scrollView = contentScrollView else { return }
        if scrollView.contentInsetAdjustmentBehavior != .never {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        // Reassigning unconditionally would invalidate layout on every pass.
        if scrollView.contentInset != .zero {
            scrollView.contentInset = .zero
        }
    }

    /// Every scale change — pinch, double tap, and PDFKit's own autoscaling — passes
    /// through here, so answering with the size-to-fit scale keeps the page fitted
    /// and refuses everything else.
    func pdfViewWillChangeScaleFactor(_ sender: PDFView, toScale scale: CGFloat) -> CGFloat {
        let fit = sender.scaleFactorForSizeToFit
        return fit > 0 && fit.isFinite ? fit : scale
    }

    /// The scroll view zooms itself for a pinch or a double tap and only tells PDFKit
    /// afterwards, so it never asks for a scale factor and the delegate above never
    /// gets the chance to refuse. The gestures have to be taken away instead.
    private func disableZoomGestures(in view: UIView) {
        if let scrollView = view as? UIScrollView, scrollView.bouncesZoom {
            scrollView.bouncesZoom = false
        }
        for recognizer in view.gestureRecognizers ?? [] {
            switch recognizer {
            case is UIPinchGestureRecognizer:
                recognizer.isEnabled = false
            case let tap as UITapGestureRecognizer where tap.numberOfTapsRequired > 1:
                tap.isEnabled = false
            default:
                break
            }
        }
        for subview in view.subviews { disableZoomGestures(in: subview) }
    }

    /// PDFKit paints the new page progressively: a coarse tile can be visible for
    /// a frame before the final tile arrives. Keep the already-sharp outgoing page
    /// over that handoff, then reveal the new page with a short native fade.
    func showPage(_ page: PDFPage, animated: Bool) {
        pageTransitionGeneration &+= 1
        let generation = pageTransitionGeneration
        pageTransitionWorkItem?.cancel()
        pageTransitionWorkItem = nil

        if animated, let snapshot = pageTransitionSnapshot() {
            let overlay = pageTransitionOverlay ?? UIImageView(frame: bounds)
            overlay.image = snapshot
            overlay.frame = bounds
            overlay.alpha = 1
            overlay.isHidden = false
            overlay.isUserInteractionEnabled = false
            if overlay.superview !== self {
                addSubview(overlay)
            } else {
                bringSubviewToFront(overlay)
            }
            pageTransitionOverlay = overlay
        } else {
            clearPageTransitionOverlay()
        }

        go(to: page)

        guard animated, let overlay = pageTransitionOverlay else { return }
        let workItem = DispatchWorkItem { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            UIView.animate(
                withDuration: Self.pageTransitionFadeDuration,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
            ) {
                overlay.alpha = 0
            } completion: { [weak self, weak overlay] _ in
                guard let self, let overlay else { return }
                if self.pageTransitionGeneration == generation,
                   self.pageTransitionOverlay === overlay {
                    self.clearPageTransitionOverlay()
                }
            }
        }
        pageTransitionWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.pageTransitionRevealDelay,
            execute: workItem
        )
    }

    private func pageTransitionSnapshot() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        pageTransitionOverlay?.isHidden = true
        layoutIfNeeded()
        // Derive the scale from this view's traits so the snapshot matches the
        // display it is actually on, rather than assuming the main screen.
        let format = UIGraphicsImageRendererFormat(for: traitCollection)
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            layer.render(in: context.cgContext)
        }
    }

    private func clearPageTransitionOverlay() {
        pageTransitionOverlay?.removeFromSuperview()
        pageTransitionOverlay?.image = nil
        pageTransitionOverlay = nil
    }

    deinit {
        pageTransitionWorkItem?.cancel()
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

    /// SwiftUI reruns this for any state the viewer touches, most of which has nothing
    /// to do with the page — a toolbar fading in, the pointer moving. Every assignment
    /// here is therefore guarded: PDFKit relays out the document and redraws the page
    /// when these are set, even when set to the value they already hold.
    func update(_ view: PDFView, cache: PDFDisplayCache, reduceMotion: Bool) {
        if view.pageShadowsEnabled { view.pageShadowsEnabled = false }
        #if os(macOS)
        let background: NSColor = invertColors ? .black : .windowBackgroundColor
        #else
        let background: UIColor = invertColors ? .black : .systemBackground
        #endif
        if view.backgroundColor != background { view.backgroundColor = background }
        let displayed = cache.document(source: document, pageIndex: pageIndex,
                                       inverted: invertColors, invertAnnotations: invertAnnotations)
        let sameDisplayedDocument = view.document === displayed
        if !sameDisplayedDocument { view.document = displayed }
        let index = displayed === document ? pageIndex : cache.renderedPageIndex(for: pageIndex) ?? 0
        if let page = displayed.page(at: index), view.currentPage !== page {
            let isPageTurn = sameDisplayedDocument && view.currentPage != nil
#if os(macOS)
            if let view = view as? ShowPDFView {
                view.showPage(page, animated: isPageTurn && !reduceMotion)
            } else {
                view.go(to: page)
            }
#else
            if let view = view as? FitPDFView {
                view.showPage(page, animated: isPageTurn && !reduceMotion)
            } else {
                view.go(to: page)
            }
#endif
        }
        // The page always scales to the window; there is no manual zoom to preserve.
        // Assigning this rescales the page, so it is only restored if something
        // actually turned it off.
        if !view.autoScales { view.autoScales = true }
    }
}
