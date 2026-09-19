import SwiftUI

private struct MIDITriggerEditor: View {
    @Bindable var controller: MIDIController
    let action: MIDINavigationAction
    @State private var isExpanded = false
    @State private var draftKind: MIDITrigger.Kind?
    @State private var draftChannel = "1"
    @State private var draftByte1 = ""
    @State private var draftByte2 = ""

    private var binding: MIDITrigger? { controller.bindings[action] }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let binding {
                Picker("Message Type", selection: Binding(
                    get: { binding.kind },
                    set: { controller.setBindingKind(action, kind: $0) }
                )) {
                    ForEach(MIDITrigger.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                valueField("Channel (1–16)", field: .channel)
                valueField("Byte 1 (0–127)", field: .byte1)
                if binding.kind != .programChange {
                    valueField("Byte 2 (0–127)", field: .byte2)
                    if binding.matchesAnyByte2 {
                        Text("Any positive Byte 2 value matches. Edit Byte 2 to use an exact value.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Clear Mapping", role: .destructive) { controller.clearBinding(action) }
            } else {
                Picker("Message Type", selection: $draftKind) {
                    Text("Choose a Message").tag(nil as MIDITrigger.Kind?)
                    ForEach(MIDITrigger.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind as MIDITrigger.Kind?)
                    }
                }
                draftField("Channel (1–16)", value: $draftChannel)
                draftField("Byte 1 (0–127)", value: $draftByte1)
                if draftKind != .programChange {
                    draftField("Byte 2 (0–127)", value: $draftByte2)
                }
                Button("Save Mapping", action: saveDraft)
                    .disabled(!draftIsValid)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title)
                    Text(controller.learningAction == action ? "Waiting for MIDI…" : bindingSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.learningAction == action {
                    Button("Cancel") { controller.cancelLearning() }
                        .accessibilityLabel("Cancel capture for \(action.title)")
                } else {
                    Button("Capture") { controller.beginLearning(action) }
                        .accessibilityLabel("Capture \(action.title)")
                        .disabled(!controller.enabled || controller.sources.isEmpty || controller.setupError != nil)
                }
            }
        }
        .onChange(of: binding) { _, newBinding in
            guard newBinding == nil else { return }
            draftKind = nil
            draftChannel = "1"
            draftByte1 = ""
            draftByte2 = ""
        }
    }

    private var bindingSummary: String {
        guard let binding else { return "Not assigned" }
        return "\(binding.kind.displayName) · Channel \(Int(binding.channel) + 1) · \(binding.byte1)"
    }

    private func valueField(_ title: String, field: MIDITriggerField) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(
                get: { controller.bindingFieldValue(action, field: field) ?? 0 },
                set: { controller.setBindingField(action, field: field, value: $0) }
            ), format: .number.grouping(.never))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .accessibilityLabel("\(action.title), \(title)")
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
        }
    }

    private func draftField(_ title: String, value: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: value)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .accessibilityLabel("\(action.title), \(title)")
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
        }
    }

    private var draftIsValid: Bool {
        guard let draftKind,
              let channel = Int(draftChannel), (1...16).contains(channel),
              let byte1 = Int(draftByte1), (0...127).contains(byte1) else { return false }
        if draftKind != .programChange {
            guard let byte2 = Int(draftByte2), (0...127).contains(byte2) else { return false }
        }
        return true
    }

    private func saveDraft() {
        guard draftIsValid, let draftKind,
              let channel = Int(draftChannel), let byte1 = Int(draftByte1) else { return }
        controller.createBinding(action, kind: draftKind, channel: channel,
                                 byte1: byte1, byte2: Int(draftByte2) ?? 0)
    }
}

private struct MIDISettingsSection: View {
    @Bindable var controller: MIDIController

    var body: some View {
        Section {
            Toggle("Enable MIDI", isOn: $controller.enabled)
                .onChange(of: controller.enabled) { _, enabled in
                    if !enabled { controller.cancelLearning() }
                }

            if let setupError = controller.setupError {
                Label(setupError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if controller.sources.isEmpty {
                LabeledContent("Input Sources", value: "No Sources")
            } else {
                Picker("Input Source", selection: $controller.inputSelection) {
                    Text("All Connected Sources").tag(MIDIInputSelection.allSources)
                    if case .source(let selectedID) = controller.inputSelection,
                       !controller.sources.contains(where: { $0.id == selectedID }) {
                        Text("Unavailable Source (\(selectedID))")
                            .tag(MIDIInputSelection.source(selectedID))
                    }
                    ForEach(controller.sources) { source in
                        Text(source.name).tag(MIDIInputSelection.source(source.id))
                    }
                }
            }

            Picker("MIDI Channel", selection: $controller.channelFilter) {
                Text("Any").tag(0)
                ForEach(1...16, id: \.self) { channel in
                    Text("Channel \(channel)").tag(channel)
                }
            }

        } header: {
            Text("MIDI Input")
        } footer: {
            Text(controller.enabled
                 ? "Supported MIDI messages from the selected source can trigger navigation."
                 : "MIDI input is disabled until Enable MIDI is turned on.")
        }

        Section {
            ForEach(MIDINavigationAction.allCases) { action in
                MIDITriggerEditor(controller: controller, action: action)
            }
        } header: {
            Text("Page Navigation")
        } footer: {
            Text("Capture a control from a connected MIDI device, or expand an action to enter its mapping manually. Capturing a control does not turn the page.")
        }

        Section {
            Toggle("Enable Program Change Recall", isOn: $controller.programChangeRecallEnabled)

            if controller.programChangeRecallEnabled {
                Stepper(
                    "Page Offset: \(controller.programChangeOffset)",
                    value: $controller.programChangeOffset,
                    in: -127...128
                )
            }
        } header: {
            Text("Program Change Page Recall")
        } footer: {
            Text("Page = Program + Offset. Program Change values are zero-based; use offset 1 for Program 0 → Page 1.")
        }

    }
}

struct GeneralSettingsView: View {
    @Bindable var model: ViewerModel
    @Bindable var oscController: OSCController
    @Bindable var midiController: MIDIController
    @Environment(\.dismiss) private var dismiss

    private enum SettingsTab: Hashable { case general, midi, osc }
    @State private var selection: SettingsTab = .general

    var body: some View {
        #if os(macOS)
        tabs
        #else
        NavigationStack {
            List {
                NavigationLink {
                    GeneralSettingsForm(model: model)
                        .navigationTitle("General")
                } label: {
                    Label("General", systemImage: "gearshape")
                }
                NavigationLink {
                    Form { MIDISettingsSection(controller: midiController) }
                        .navigationTitle("MIDI")
                        .onDisappear { midiController.cancelLearning() }
                } label: {
                    Label("MIDI", systemImage: "pianokeys")
                }
                NavigationLink {
                    OSCSettingsForm(controller: oscController)
                        .navigationTitle("OSC")
                } label: {
                    Label("OSC", systemImage: "network")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onDisappear { midiController.cancelLearning() }
        #endif
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            GeneralSettingsForm(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            Form { MIDISettingsSection(controller: midiController) }
                .tabItem { Label("MIDI", systemImage: "pianokeys") }
                .tag(SettingsTab.midi)
            OSCSettingsForm(controller: oscController)
                .tabItem { Label("OSC", systemImage: "network") }
                .tag(SettingsTab.osc)
        }
        .formStyle(.grouped)
        .onChange(of: selection) { midiController.cancelLearning() }
        .onDisappear { midiController.cancelLearning() }
    }
}

private struct GeneralSettingsForm: View {
    @Bindable var model: ViewerModel

    var body: some View {
        Form {
            Section("Startup") {
                Picker("Open Documents At", selection: $model.startupBehavior) {
                    Text("First Page").tag(StartupBehavior.firstPage)
                    Text("Last Viewed Page").tag(StartupBehavior.resumeLastPage)
                }
            }

            Section {
                Picker("PDF Colors", selection: $model.pdfColorAppearance) {
                    Text("Match System Appearance").tag(PDFColorAppearance.matchSystem)
                    Text("Normal").tag(PDFColorAppearance.normal)
                    Text("Inverted").tag(PDFColorAppearance.inverted)
                }
                Toggle("Invert Annotations", isOn: $model.invertAnnotations)
                    .disabled(!model.invertPDFColors)

            } header: {
                Text("PDF Appearance")
            } footer: {
                Text("Matching the system appearance inverts pages in Dark Mode. Annotation colors are preserved unless you invert them with the page; marks flattened into the page always invert. The original PDF is unchanged.")
            }

            Section {
                Toggle("Keep Screen Awake", isOn: $model.keepScreenAwake)
            } header: {
                Text("During a Show")
            } footer: {
                Text("Prevents sleep while a document is open. On iPad, Viewtiful must remain in the foreground.")
            }

            Section {
                Toggle("Tap Screen Edges to Turn Pages", isOn: $model.edgeTapNavigationEnabled)
            } header: {
                Text("Page Navigation")
            } footer: {
                Text("Tap an edge to turn a page. Tap the center to show or hide controls. You can also swipe or use a keyboard, MIDI, or OSC.")
            }
        }
    }
}

private struct OSCSettingsForm: View {
    @Bindable var controller: OSCController

    var body: some View {
        Form {
            Section("Listener") {
                Toggle("Enable OSC", isOn: $controller.enabled)

                LabeledContent("Device IP Address") {
                    if controller.localAddresses.isEmpty {
                        Text("No active IPv4 address")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(controller.localAddresses.map { "\($0.interfaceName): \($0.address)" }.joined(separator: "\n"))
                            .fontDesign(.monospaced)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }

                LabeledContent("Listener Status") {
                    switch controller.status {
                    case .running:
                        Label("Running", systemImage: "checkmark.circle")
                    case .starting:
                        Label("Starting", systemImage: "ellipsis.circle")
                    case .stopped:
                        Text(controller.enabled ? "Stopped" : "Disabled")
                    case .failed(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle")
                    }
                }

                if case .failed = controller.status {
                    Button("Retry Listener", systemImage: "arrow.clockwise") {
                        controller.applyConfiguration()
                    }
                }

                LabeledContent("UDP Listen Port") {
                    TextField("Port", value: $controller.port, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .accessibilityLabel("UDP Listen Port")
                        #if !os(macOS)
                        .keyboardType(.numberPad)
                        #endif
                }

                Text("Send OSC over UDP to one of the addresses above on the selected port.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Sender Restriction") {
                Toggle("Restrict to One Sender", isOn: $controller.senderRestrictionEnabled)

                if controller.senderRestrictionEnabled {
                    TextField("Allowed Sender IP", text: $controller.allowedSenderAddress)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        #endif

                    Text("Only commands from this exact IP address are accepted. Leave it blank only while configuring; no sender is accepted until an address is entered.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Viewtiful accepts OSC commands from any sender on the local network.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Commands") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("/viewtiful/next")
                    Text("/viewtiful/previous")
                    Text("/viewtiful/first")
                    Text("/viewtiful/last")
                    Text("/viewtiful/page/{page_number}")
                }
                .fontDesign(.monospaced)
                .textSelection(.enabled)
            }
        }
    }
}
