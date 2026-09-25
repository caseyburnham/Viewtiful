#if os(macOS)
import AppKit
import SwiftUI

/// Hides the pointer while the viewer is full screen, bringing it back as soon as the
/// mouse moves and hiding it again once it has been still for a moment.
@MainActor
final class PointerHider {
    private static let idleDelay = Duration.seconds(3)

    private var monitor: Any?
    private var rearm: Task<Void, Never>?
    private weak var window: NSWindow?
    private var windowAcceptedMouseMoved = false

    var isActive: Bool { monitor != nil }

    func begin(in window: NSWindow) {
        guard monitor == nil else { return }

        self.window = window
        windowAcceptedMouseMoved = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true

        // Observed, not consumed: the toolbar hover monitor needs the same events.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.scheduleHide()
            return event
        }

        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func end() {
        rearm?.cancel()
        rearm = nil

        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        window?.acceptsMouseMovedEvents = windowAcceptedMouseMoved
        window = nil

        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func scheduleHide() {
        rearm?.cancel()
        rearm = Task {
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// Runs a `PointerHider` for as long as its window is full screen and `isEnabled`
/// holds, which the viewer ties to having a document open.
struct FullScreenPointerHiding: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> ObservingView { ObservingView() }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: ObservingView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObservingView: NSView {
        private let hider = PointerHider()
        private var observers: [NSObjectProtocol] = []

        var isEnabled = false {
            didSet { if isEnabled != oldValue { refresh() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            refresh()
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            hider.end()
        }

        private func refresh() {
            guard let window, isEnabled, window.styleMask.contains(.fullScreen) else {
                if hider.isActive { hider.end() }
                return
            }
            hider.begin(in: window)
        }
    }
}
#endif
