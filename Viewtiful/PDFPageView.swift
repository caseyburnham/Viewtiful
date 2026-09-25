import PDFKit
import SwiftUI

#if os(macOS)
struct PDFPageView: NSViewRepresentable {
    let document: ShowDocument
    let pageIndex: Int
    let invertColors: Bool
    let invertAnnotations: Bool
    /// Fills the space the fitted page does not cover with paper rather than window
    /// chrome, so a margin around the page looks like the page's own border.
    let usesPaperBackground: Bool
    /// How far a swipe in progress has carried the page.
    let dragOffset: CGFloat
    let reduceMotion: Bool
    let onPageTurn: (ViewtifulAction) -> Void

    func makeNSView(context: Context) -> ShowPDFView {
        let view = ShowPDFView()
        configure(view)
        view.onPageTurn = onPageTurn
        update(view, warmer: context.coordinator)
        return view
    }

    func updateNSView(_ view: ShowPDFView, context: Context) {
        view.onPageTurn = onPageTurn
        if context.coordinator.source !== document { view.needsWindowFit = true }
        update(view, warmer: context.coordinator)
        view.fitWindowIfNeeded()
    }

    /// The window only keeps the page's shape while there is a page to keep.
    static func dismantleNSView(_ view: ShowPDFView, coordinator: PageWarmer) {
        view.releaseWindowShape()
    }
}

/// PDFKit owns rendering and accessibility. The show viewer owns page navigation.
final class ShowPDFView: PDFView, PDFViewDelegate, PageTurnHosting {
    var onPageTurn: ((ViewtifulAction) -> Void)?
    var needsWindowFit = true
    let pageTurnAnimator = PageTurnAnimator()
    var pageContentLayer: CALayer? { firstScrollView(in: self)?.layer }
    var pageHostLayer: CALayer? { layer }
    private var scrollNavigation = ScrollPageNavigation()
    private var isWindowFitScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        // Page turns animate the view's layer, so it needs one of its own.
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
        wantsLayer = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep PDFKit's internal scroll view from independently changing the page.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override var acceptsFirstResponder: Bool { true }

    /// Go to Page (⌘L) is left to its menu item, which handles it before this view sees it.
    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        if let action = Self.pageAction(for: event) {
            onPageTurn?(action)
        } else if event.charactersIgnoringModifiers != "\u{1B}" {
            // Escape is swallowed so that dismissing nothing doesn't beep mid-show.
            super.keyDown(with: event)
        }
    }

    private static func pageAction(for event: NSEvent) -> ViewtifulAction? {
        switch event.specialKey {
        case .rightArrow?, .pageDown?: return .nextPage
        case .leftArrow?, .pageUp?: return .previousPage
        case .home?: return .firstPage
        case .end?: return .lastPage
        default: break
        }
        guard event.charactersIgnoringModifiers == " " else { return nil }
        return event.modifierFlags.contains(.shift) ? .previousPage : .nextPage
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
        guard window != nil else { return }
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

    /// Gives the window the page's shape and holds it there, so resizing the window
    /// scales the page rather than opening bars beside it. The window keeps its height
    /// and center and only its width changes, once, when a document is opened.
    func fitWindowIfNeeded() {
        guard needsWindowFit, bounds.height > 0, let window, let page = currentPage else { return }
        needsWindowFit = false
        var pageSize = page.bounds(for: .cropBox).size
        if abs(page.rotation) % 180 == 90 { swap(&pageSize.width, &pageSize.height) }
        guard pageSize.width > 0, pageSize.height > 0 else { return }

        window.contentAspectRatio = pageSize
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let visible = window.screen?.visibleFrame else { return }

        var content = window.contentRect(forFrameRect: window.frame)
        let width = content.height * pageSize.width / pageSize.height
        content.origin.x += (content.width - width) / 2
        content.size.width = width
        var frame = window.frameRect(forContentRect: content)
        frame.size.width = min(max(frame.width, window.minSize.width), visible.width)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        window.setFrame(frame, display: true)
    }

    /// Returns the window to free resizing once no page is being shown.
    func releaseWindowShape() {
        window?.contentResizeIncrements = NSSize(width: 1, height: 1)
    }
}
#else
struct PDFPageView: UIViewRepresentable {
    let document: ShowDocument
    let pageIndex: Int
    let invertColors: Bool
    let invertAnnotations: Bool
    /// Fills the space the fitted page does not cover with paper rather than window
    /// chrome, so a margin around the page looks like the page's own border.
    let usesPaperBackground: Bool
    /// How far a swipe in progress has carried the page.
    let dragOffset: CGFloat
    let reduceMotion: Bool
    let onPageTurn: (ViewtifulAction) -> Void

    func makeUIView(context: Context) -> FitPDFView {
        let view = FitPDFView()
        configure(view)
        update(view, warmer: context.coordinator)
        return view
    }

    func updateUIView(_ view: FitPDFView, context: Context) {
        update(view, warmer: context.coordinator)
    }
}

/// Zooming is off: the page is always drawn at the largest scale that fits the view.
final class FitPDFView: PDFView, PDFViewDelegate, PageTurnHosting {
    let pageTurnAnimator = PageTurnAnimator()
    var pageContentLayer: CALayer? { contentScrollView?.layer }
    var pageHostLayer: CALayer? { layer }

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
    func makeCoordinator() -> PageWarmer { PageWarmer() }

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
    func update(_ view: any PageTurnHosting, warmer: PageWarmer) {
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

        // Set before any turn, so the incoming page is drawn in the new colors from
        // its first tile.
        let appearance = PageAppearance(inverted: invertColors, invertAnnotations: invertAnnotations)
        let appearanceChanged = document.appearance != appearance
        if appearanceChanged { document.appearance = appearance }

        if view.document !== document {
            view.document = document
        } else if appearanceChanged, let shown = view.currentPage {
            // PDFKit keeps a page's tiles for as long as the view holds its document,
            // and nothing public tells it the page now draws differently. Handing it
            // the document again rebuilds them; the crossfade covers the swap.
            view.pageTurnAnimator.crossfade(in: view) {
                view.document = nil
                view.document = document
                view.go(to: shown)
            }
        }
        if let page = document.page(at: pageIndex), view.currentPage !== page {
            view.pageTurnAnimator.turn(to: pageIndex, of: document, reduceMotion: reduceMotion, in: view) {
                view.go(to: page)
            }
        }
        warmer.warm(around: pageIndex, in: document)

        // After any turn, so a release that turned the page hands its offset to the
        // turn rather than springing back first.
        view.pageTurnAnimator.follow(dragOffset: dragOffset, reduceMotion: reduceMotion, in: view)

        // The page always scales to the window; there is no manual zoom to preserve.
        // Assigning this rescales the page, so it is only restored if something
        // actually turned it off.
        if !view.autoScales { view.autoScales = true }
    }
}
