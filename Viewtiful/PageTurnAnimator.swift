import PDFKit
import QuartzCore

/// A PDF view that can animate turning from one page to the next.
@MainActor
protocol PageTurnHosting: PDFView {
    var pageTurnAnimator: PageTurnAnimator { get }
    /// The layer PDFKit draws pages into, which is what slides and follows a swipe.
    var pageContentLayer: CALayer? { get }
    /// The view's own layer, which carries the crossfade over everything beneath it.
    var pageHostLayer: CALayer? { get }
}

/// Turns pages with a crossfade and a short slide in the direction of travel, and
/// lets a swipe carry the page with the finger before it turns.
///
/// Core Animation does the work: a fade transition on the host layer keeps the
/// outgoing page as it was last drawn — dragged partway, if it was — while the
/// incoming one springs into place beneath it. Nothing here copies or re-renders a
/// page, and every animation is additive and presentation-only, so neither AppKit
/// nor UIKit ever finds a layer left somewhere it did not put it.
@MainActor
final class PageTurnAnimator {
    /// The slide is a fraction of the width, and capped, so it reads as a direction of
    /// travel rather than the page flying across a wide screen.
    private static let slideFraction: CGFloat = 0.1
    private static let maximumSlide: CGFloat = 96
    private static let slideDuration: CFTimeInterval = 0.34
    private static let fadeDuration: CFTimeInterval = 0.24
    private static let translationKeyPath = "transform.translation.x"

    private enum AnimationKey {
        static let fade = "pageTurn.fade"
        static let slide = "pageTurn.slide"
        static let drag = "pageTurn.drag"
    }

    /// The show and page last put on screen, in the source document's own order.
    /// A different show is a fresh start rather than a page turn.
    private weak var shownDocument: PDFDocument?
    private var shownPageIndex: Int?
    private var heldOffset: CGFloat = 0

    /// Runs `change`, animated as a turn when it moves from one page of the same show
    /// to another. Anything else — a new show, the same page redisplayed with new
    /// colors — changes without animation.
    func turn(to pageIndex: Int, of document: PDFDocument, reduceMotion: Bool,
              in view: any PageTurnHosting, change: () -> Void) {
        let previousIndex = shownDocument === document ? shownPageIndex : nil
        shownDocument = document
        shownPageIndex = pageIndex

        guard let previousIndex, previousIndex != pageIndex, let host = view.pageHostLayer else {
            releaseDrag(from: view.pageContentLayer)
            change()
            return
        }

        host.add(Self.fade(), forKey: AnimationKey.fade)

        let content = view.pageContentLayer
        releaseDrag(from: content)
        change()

        // A crossfade alone is the Reduce Motion version: nothing moves.
        guard !reduceMotion, let content else { return }
        let direction = Self.direction(from: previousIndex, to: pageIndex, pageCount: document.pageCount)
        let distance = min(view.bounds.width * Self.slideFraction, Self.maximumSlide)
        content.add(Self.settle(from: direction * distance), forKey: AnimationKey.slide)
    }

    /// Runs `change` behind a crossfade and nothing else, for the same page shown
    /// differently. Nothing moves, so this is the same with Reduce Motion on.
    func crossfade(in view: any PageTurnHosting, change: () -> Void) {
        view.pageHostLayer?.add(Self.fade(), forKey: AnimationKey.fade)
        change()
    }

    /// Keeps the page `offset` points from where it rests while a swipe is under way.
    /// An offset of zero with no turn to follow springs the page back into place.
    func follow(dragOffset offset: CGFloat, reduceMotion: Bool, in view: any PageTurnHosting) {
        guard offset != heldOffset, let content = view.pageContentLayer else { return }
        let released = heldOffset
        heldOffset = offset

        guard offset == 0 else {
            let hold = CABasicAnimation(keyPath: Self.translationKeyPath)
            hold.isAdditive = true
            hold.fromValue = offset
            hold.toValue = offset
            hold.duration = .greatestFiniteMagnitude
            hold.isRemovedOnCompletion = false
            hold.fillMode = .both
            content.add(hold, forKey: AnimationKey.drag)
            return
        }

        content.removeAnimation(forKey: AnimationKey.drag)
        guard !reduceMotion else { return }
        content.add(Self.settle(from: released), forKey: AnimationKey.slide)
    }

    /// Lets go of a swipe the turn is taking over. The fade has already kept the
    /// outgoing page where the finger left it.
    private func releaseDrag(from content: CALayer?) {
        guard heldOffset != 0 else { return }
        heldOffset = 0
        content?.removeAnimation(forKey: AnimationKey.drag)
    }

    private static func fade() -> CATransition {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return fade
    }

    /// An additive spring from `offset` back to where the layer actually is.
    private static func settle(from offset: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: slideDuration, bounce: 0)
        spring.keyPath = translationKeyPath
        spring.isAdditive = true
        spring.fromValue = offset
        spring.toValue = 0
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Forward is +1: the new page arrives from the trailing side. Stepping off one end
    /// onto the other still reads as a single step forward or back.
    private static func direction(from old: Int, to new: Int, pageCount: Int) -> CGFloat {
        if pageCount > 2 {
            if new == (old + 1) % pageCount { return 1 }
            if new == (old - 1 + pageCount) % pageCount { return -1 }
        }
        return new > old ? 1 : -1
    }
}
