import ObjectiveC
import PDFKit
import SwiftUI

#if os(macOS)
struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let invertColors: Bool
    let invertAnnotations: Bool
    /// Fills the space the fitted page does not cover with paper rather than window
    /// chrome, so a margin around the page looks like the page's own border.
    let usesPaperBackground: Bool
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
    }
}

/// PDFKit owns rendering and accessibility. The show viewer owns page navigation.
final class ShowPDFView: PDFView, PDFViewDelegate {
    /// PDFKit builds a page's annotation layers a frame or two after laying the page
    /// out, so a sweep has to outlast that without running indefinitely.
    private static let annotationSweepFrames = 30
    /// Once a sweep has corrected something the layers exist, so only a couple more
    /// frames are needed to catch any arriving in the same batch.
    private static let annotationSweepSettleFrames = 2
    private static let windowFitDuration = 0.2

    var onPageTurn: ((ViewtifulAction) -> Void)?
    var onGoToPage: (() -> Void)?
    var needsWindowFit = true
    private var scrollNavigation = ScrollPageNavigation()
    private var pendingAnnotationScaleFrames = 0
    private var annotationSweepLink: CADisplayLink?
    /// What the last sweep was scheduled for. A layout that changes neither leaves
    /// the annotation layers alone.
    private var sweptScale: CGFloat = 0
    private weak var sweptPage: PDFPage?
    private var isWindowFitScheduled = false

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
        guard window != nil else {
            // The sweep's display link retains this view, so a document that closes
            // mid-sweep would otherwise stay alive redrawing layers nobody can see.
            stopAnnotationSweep()
            return
        }
        // Wait for SwiftUI to lay out the document viewport before sizing its window.
        scheduleWindowFit()
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
        scheduleWindowFit()
        // Only a new page or a new scale can leave an annotation layer rasterized at
        // the wrong resolution. Layouts that change neither — insets being re-cleared,
        // the toolbar coming and going — would otherwise restart half a second of
        // layer-tree walking every time they ran, which during a live resize is every
        // frame. Checking the page here also covers a page delivered asynchronously,
        // which never passes back through `updateNSView`.
        if annotationLayerScale != sweptScale || currentPage !== sweptPage {
            scheduleAnnotationLayerScaleFix()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleAnnotationLayerScaleFix()
    }

    // MARK: - Annotation layer resolution

    /// PDFKit gives each page tile a contentsScale of the view's scale times the
    /// screen's backing scale, but builds a layer per annotation and leaves those
    /// at 1.0. Ink and shape markup is then rasterized at a fifth of the page's
    /// resolution and upscaled, so it looks blocky next to crisp page text.
    ///
    /// Those layers are built inside PDFKit's own transaction a frame or two
    /// after the page is laid out, so there is no view callback that lands once
    /// they exist. Sweep for them over the next few frames instead, and stop as
    /// soon as a sweep has corrected some and a couple of frames have settled.
    private func scheduleAnnotationLayerScaleFix() {
        sweptScale = annotationLayerScale
        sweptPage = currentPage
        pendingAnnotationScaleFrames = Self.annotationSweepFrames
        startAnnotationSweep()
    }

    private func startAnnotationSweep() {
        guard annotationSweepLink == nil, window != nil else { return }
        // The layers being corrected are composited by Core Animation, so there is
        // nothing to gain from looking for them more often than the screen redraws.
        let link = displayLink(target: self, selector: #selector(runAnnotationScalePass))
        link.add(to: .main, forMode: .common)
        annotationSweepLink = link
    }

    private func stopAnnotationSweep() {
        pendingAnnotationScaleFrames = 0
        annotationSweepLink?.invalidate()
        annotationSweepLink = nil
    }

    @objc private func runAnnotationScalePass() {
        guard pendingAnnotationScaleFrames > 0 else {
            stopAnnotationSweep()
            return
        }
        pendingAnnotationScaleFrames -= 1
        if matchAnnotationLayerScale() > 0 {
            pendingAnnotationScaleFrames = min(pendingAnnotationScaleFrames,
                                               Self.annotationSweepSettleFrames)
        }
        if pendingAnnotationScaleFrames == 0 { stopAnnotationSweep() }
    }

    /// The resolution PDFKit should be rasterizing this page's annotations at.
    private var annotationLayerScale: CGFloat {
        guard let window else { return 0 }
        let scale = scaleFactor * window.backingScaleFactor
        return scale > 0 && scale.isFinite ? scale : 0
    }

    /// Returns how many layers needed correcting, so the sweep knows when the
    /// page's annotation layers have shown up.
    @discardableResult
    private func matchAnnotationLayerScale() -> Int {
        guard let root = layer else { return 0 }
        let scale = annotationLayerScale
        guard scale > 0 else { return 0 }
        return applyAnnotationScale(scale, to: root, insideAnnotation: false)
    }

    private func applyAnnotationScale(_ scale: CGFloat, to layer: CALayer, insideAnnotation: Bool) -> Int {
        var corrected = 0
        let isAnnotation = insideAnnotation || Self.isAnnotationLayer(layer)
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

    /// PDFKit's annotation layers are private types, so they are recognised by name.
    /// `String(describing:)` would allocate a string for every layer on every frame
    /// of the sweep; the class name is already a C string and is searched in place.
    private static func isAnnotationLayer(_ layer: CALayer) -> Bool {
        strstr(class_getName(type(of: layer)), "Annotation") != nil
    }

    // MARK: - Window fit

    private func scheduleWindowFit() {
        // A fit that cannot run yet — no window, no page, no height — leaves
        // `needsWindowFit` set, and layout runs often enough that re-enqueuing on
        // every pass would pile up blocks that all do the same single piece of work.
        guard needsWindowFit, !isWindowFitScheduled else { return }
        isWindowFitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isWindowFitScheduled = false
            self.fitWindowIfNeeded()
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
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(frame, display: true)
            return
        }
        // `setFrame(_:display:animate:)` runs its animation by blocking the main
        // thread, stalling the document's first layout behind it for the duration.
        // The animator proxy gives the same movement without holding anything up.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.windowFitDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}
#else
struct PDFPageView: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let invertColors: Bool
    let invertAnnotations: Bool
    /// Fills the space the fitted page does not cover with paper rather than window
    /// chrome, so a margin around the page looks like the page's own border.
    let usesPaperBackground: Bool
    let onPageTurn: (ViewtifulAction) -> Void
    let onGoToPage: () -> Void

    func makeUIView(context: Context) -> FitPDFView {
        let view = FitPDFView()
        configure(view)
        update(view, cache: context.coordinator)
        return view
    }

    func updateUIView(_ view: FitPDFView, context: Context) {
        update(view, cache: context.coordinator)
    }
}

/// Zooming is off: the page is always drawn at the largest scale that fits the view.
final class FitPDFView: PDFView, PDFViewDelegate {
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
}
#endif

extension PDFPageView {
    func makeCoordinator() -> PDFDisplayCache { PDFDisplayCache() }

    func configure(_ view: PDFView) {
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.displaysPageBreaks = false
        view.autoScales = true
        // Scanned scripts are page-sized images being fitted to the viewport, which
        // is a resample on every draw. The default quality shows as a soft page.
        view.interpolationQuality = .high
    }

    /// SwiftUI reruns this for any state the viewer touches, most of which has nothing
    /// to do with the page — a toolbar fading in, the pointer moving. Every assignment
    /// here is therefore guarded: PDFKit relays out the document and redraws the page
    /// when these are set, even when set to the value they already hold.
    func update(_ view: PDFView, cache: PDFDisplayCache) {
        if view.pageShadowsEnabled { view.pageShadowsEnabled = false }
        // Paper white and black are fixed rather than dynamic: they have to match the
        // page PDFKit is drawing, not the system's current appearance.
        #if os(macOS)
        let background: NSColor = invertColors
            ? .black
            : (usesPaperBackground ? .white : .windowBackgroundColor)
        #else
        let background: UIColor = invertColors
            ? .black
            : (usesPaperBackground ? .white : .systemBackground)
        #endif
        if view.backgroundColor != background { view.backgroundColor = background }

        // An inverted page that has not been built yet arrives here rather than
        // holding up the turn. Until it does the view keeps the page it is already
        // showing, which is a better thing to look at than a half-drawn one.
        cache.onPageReady = { [weak view] displayed, index in
            guard let view else { return }
            show(displayed, pageIndex: index, in: view)
        }
        if let target = cache.target(source: document, pageIndex: pageIndex,
                                     inverted: invertColors, invertAnnotations: invertAnnotations) {
            show(target.document, pageIndex: target.pageIndex, in: view)
        }

        // The page always scales to the window; there is no manual zoom to preserve.
        // Assigning this rescales the page, so it is only restored if something
        // actually turned it off.
        if !view.autoScales { view.autoScales = true }
    }

    private func show(_ displayed: PDFDocument, pageIndex: Int, in view: PDFView) {
        if view.document !== displayed { view.document = displayed }
        guard let page = displayed.page(at: pageIndex), view.currentPage !== page else { return }
        view.go(to: page)
    }
}
