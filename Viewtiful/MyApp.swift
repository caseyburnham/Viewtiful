import SwiftUI

@main
struct Viewtiful: App {
    @State private var model = ViewerModel()
    @State private var oscController = OSCController()
    @State private var midiController = MIDIController()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, oscController: oscController, midiController: midiController)
        }

        #if os(macOS)
        Settings {
            GeneralSettingsView(model: model, oscController: oscController, midiController: midiController, showsDoneButton: false)
                .scenePadding()
                .frame(width: 420)
        }
        #endif
    }
}
