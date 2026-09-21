import SwiftUI
#if os(macOS)
import AppKit

/// Viewtiful's Mac scenes are single explicitly-opened windows rather than a document
/// group, so closing the viewer leaves nothing to return to and no reason to keep the
/// app running. Settings and the Activity Log are windows in their own right, so the
/// app still stays up while either of those is open.
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        Window("Viewtiful", id: "viewer") {
            ContentView(model: model, oscController: oscController, midiController: midiController,
                        activityLog: activityLog)
                .frame(minWidth: 360, minHeight: 480)
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            ViewerCommands(
                requestPresentation: { model.requestPresentation($0) },
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
}
