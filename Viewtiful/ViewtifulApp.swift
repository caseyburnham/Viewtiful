import SwiftUI

@main
struct ViewtifulApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var model = ViewerModel()
    @State private var oscController = OSCController()
    @State private var midiController = MIDIController()

    var body: some Scene {
        #if os(macOS)
        Window("Viewtiful", id: "viewer") {
            ContentView(model: model, oscController: oscController, midiController: midiController)
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

        Window("Monitors", id: "monitors") {
            MonitorView(midiController: midiController, oscController: oscController)
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentMinSize)
        #else
        WindowGroup {
            ContentView(model: model, oscController: oscController, midiController: midiController)
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
