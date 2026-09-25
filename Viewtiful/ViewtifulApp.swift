import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Launches the way Preview does: with no viewer on screen, Viewtiful offers the
/// standalone Open panel instead of an empty window, and the viewer only appears
/// once a show has been chosen. Cancelling leaves the app running with no windows,
/// and clicking it in the Dock offers the panel again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Loads the chosen PDF and brings up the viewer. Set by the app's scene body,
    /// the only place the model and the `openWindow` action are both at hand.
    var openDocument: ((URL) -> Void)?
    private var openPanel: NSOpenPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A PDF opened from the Finder arrives as part of launching, and SwiftUI puts
        // up its window in response. Waiting a turn lets that window appear first, so
        // the panel only shows when Viewtiful was launched with nothing to open.
        DispatchQueue.main.async { [self] in
            if !hasVisibleWindows {
                presentOpenPanel()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        presentOpenPanel()
        return false
    }

    /// Cancelling the panel or closing the viewer leaves Viewtiful ready to open the
    /// next show, as Preview does, rather than quitting out from under the person.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Shows the standalone Open panel, or brings it forward if it is already up.
    func presentOpenPanel() {
        if let openPanel {
            openPanel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        openPanel = panel
        NSApp.activate()

        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openPanel = nil
                if response == .OK, let url = panel.url {
                    self.openDocument?(url)
                }
            }
        }
    }

    private var hasVisibleWindows: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }
}
#endif

@main
@MainActor
struct ViewtifulApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.openWindow) private var openWindow
    @State private var model = ViewerModel()
    @State private var activityLog: ActivityLog
    @State private var oscController: OSCClient
    @State private var midiController: MIDIController

    init() {
        // Both controllers report to the one log, so the Activity Log window
        // shows MIDI and OSC in the order they actually arrived.
        let log = ActivityLog()
        _activityLog = State(initialValue: log)
        _oscController = State(initialValue: OSCClient(log: log))
        _midiController = State(initialValue: MIDIController(log: log))
    }

    var body: some Scene {
        #if os(macOS)
        let _ = connectOpenPanel()

        Window("Viewtiful", id: "viewer") {
            ContentView(model: model, oscController: oscController, midiController: midiController,
                        activityLog: activityLog)
                .frame(minWidth: 360, minHeight: 480)
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        // The launch Open panel stands in for the empty viewer, and a restored viewer
        // would come back without its show, so the viewer only opens once one is chosen.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            ViewerCommands(
                presentOpenPanel: { appDelegate.presentOpenPanel() },
                openViewer: { openWindow(id: "viewer") }
            )
        }

        Window("Activity Log", id: "activity-log") {
            ActivityLogView(log: activityLog)
        }
        .defaultSize(width: 820, height: 480)
        .windowResizability(.contentMinSize)
        #else
        WindowGroup {
            ContentView(model: model, oscController: oscController, midiController: midiController,
                        activityLog: activityLog)
        }

        #endif

        #if os(macOS)
        Settings {
            GeneralSettingsView(model: model, oscController: oscController, midiController: midiController)
                .frame(minWidth: 480, idealWidth: 560, minHeight: 440, idealHeight: 560)
        }
        .defaultSize(width: 560, height: 560)
        .windowResizability(.contentMinSize)
        #endif
    }

    #if os(macOS)
    /// Hands the delegate what a pick from the standalone Open panel needs: the
    /// show loaded into the model, and the viewer window brought up to display it.
    private func connectOpenPanel() {
        appDelegate.openDocument = { [model, openWindow] url in
            model.openDocument(at: url)
            openWindow(id: "viewer")
        }
    }
    #endif
}
