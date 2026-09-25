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
                valueField("Channel", field: .channel)
                valueField(binding.kind.byte1Title, field: .byte1,
                           noteName: binding.kind == .note ? MIDINoteName.name(for: binding.byte1) : nil)
                if binding.kind.matchesValue, let byte2Title = binding.kind.byte2Title {
                    valueField(byte2Title, field: .byte2)
                    if binding.matchesAnyByte2 {
                        Text("Matches any \(byte2Title.lowercased()) above 0. Enter a value to match it exactly.")
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
                if let draftKind {
                    draftField("Channel", field: .channel, value: $draftChannel)
                    draftField(draftKind.byte1Title, field: .byte1, value: $draftByte1,
                               noteName: draftKind == .note ? draftNoteName : nil)
                    if draftKind.matchesValue, let byte2Title = draftKind.byte2Title {
                        draftField(byte2Title, field: .byte2, value: $draftByte2)
                    }
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
        return "\(binding.kind.displayName) · Channel \(Int(binding.channel) + 1) · "
            + "\(binding.kind.byte1Title) \(binding.kind.describeByte1(binding.byte1))"
    }

    private var draftNoteName: String? {
        guard let note = UInt8(draftByte1), note <= 127 else { return nil }
        return MIDINoteName.name(for: note)
    }

    /// Channels count from 1 as controllers print them; data bytes from 0.
    private static func range(of field: MIDITriggerField) -> ClosedRange<Int> {
        field == .channel ? 1...16 : 0...127
    }

    private func valueField(_ title: String, field: MIDITriggerField, noteName: String? = nil) -> some View {
        LabeledContent {
            HStack {
                if let noteName {
                    Text(noteName)
                        .foregroundStyle(.secondary)
                }
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
        } label: {
            fieldLabel(title, field: field)
        }
    }

    private func draftField(_ title: String, field: MIDITriggerField, value: Binding<String>,
                            noteName: String? = nil) -> some View {
        LabeledContent {
            HStack {
                if let noteName {
                    Text(noteName)
                        .foregroundStyle(.secondary)
                }
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
        } label: {
            fieldLabel(title, field: field)
        }
    }

    /// Two texts rather than a stack, so the form styles the range as a subtitle.
    @ViewBuilder
    private func fieldLabel(_ title: String, field: MIDITriggerField) -> some View {
        let range = Self.range(of: field)
        Text(title)
        Text("\(range.lowerBound)–\(range.upperBound)")
    }

    private var draftIsValid: Bool {
        guard let draftKind,
              let channel = Int(draftChannel), (1...16).contains(channel),
              let byte1 = Int(draftByte1), (0...127).contains(byte1) else { return false }
        if draftKind.matchesValue {
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
        }

        Section {
            ForEach(MIDINavigationAction.allCases) { action in
                MIDITriggerEditor(controller: controller, action: action)
            }
        } header: {
            Text("Page Navigation")
        } footer: {
            Text("Capture a control from your device, or expand an action to enter it by hand.")
        }

        Section {
            Toggle("Recall Pages with Program Change", isOn: $controller.programChangeRecallEnabled)
        } header: {
            Text("Program Change")
        } footer: {
            Text("Program 0 recalls page 1, using the document’s page numbering.")
        }

    }
}

struct GeneralSettingsView: View {
    @Bindable var model: ViewerModel
    @Bindable var oscController: OSCClient
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
                Text("Match System inverts pages in Dark Mode. Annotations keep their colors unless inverted too.")
            }

            Section {
                Picker("Margin", selection: $model.pageMargin) {
                    ForEach(PageMargin.allCases) { margin in
                        Text(margin.displayName).tag(margin)
                    }
                }
            } header: {
                Text("Margin")
            } footer: {
                Text("A border around the page, in the page’s own color.")
            }

            Section {
                Toggle("Keep Screen Awake", isOn: $model.keepScreenAwake)
            } header: {
                Text("During a Show")
            } footer: {
                Text("Prevents sleep while a document is open. On iPad, Viewtiful must stay in the foreground.")
            }

            Section {
                #if !os(macOS)
                Toggle("Tap Screen Edges to Turn Pages", isOn: $model.edgeTapNavigationEnabled)
                #endif
                Toggle("Wrap Around at the End", isOn: $model.wrapsAround)
            } header: {
                Text("Page Navigation")
            } footer: {
                Text("Wrapping around turns from the last page back to the first, ready for the next show.")
            }

            RecentDocumentsSection(model: model)
        }
    }
}

private struct RecentDocumentsSection: View {
    @Bindable var model: ViewerModel

    var body: some View {
        Section {
            if model.recentDocuments.isEmpty {
                Text("No recent documents.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.recentDocuments) { recent in
                    row(for: recent)
                }
                .onDelete(perform: remove)

                Button("Clear Recent Documents", role: .destructive) {
                    model.clearRecentDocuments()
                }
            }
        } header: {
            Text("Recent Documents")
        } footer: {
            Text("Each document remembers its last page and page numbering. Removing one doesn’t delete the file.")
        }
    }

    private func row(for recent: RecentDocument) -> some View {
        LabeledContent {
            if !model.canRemoveRecentDocument(recent) {
                Text("Open")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(recent.displayName)
            Text(recent.lastOpened, format: .relative(presentation: .named))
        }
        // Swiping covers iPad; the Mac has no swipe, so the same action is offered
        // where a Mac list expects to find it.
        .contextMenu {
            Button("Remove", role: .destructive) { model.removeRecentDocument(recent) }
                .disabled(!model.canRemoveRecentDocument(recent))
        }
    }

    /// Resolved to documents before anything is removed, so the offsets handed over
    /// are not invalidated partway through.
    private func remove(at offsets: IndexSet) {
        for recent in offsets.map({ model.recentDocuments[$0] }) {
            model.removeRecentDocument(recent)
        }
    }
}

private struct OSCSettingsForm: View {
    @Bindable var controller: OSCClient

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("Listener")
            } footer: {
                Text("Send OSC over UDP to one of these addresses on this port.")
            }

            Section {
                Toggle("Restrict to One Sender", isOn: $controller.senderRestrictionEnabled)

                if controller.senderRestrictionEnabled {
                    TextField("Allowed Sender IP", text: $controller.allowedSenderAddress)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                }
            } header: {
                Text("Sender Restriction")
            } footer: {
                if controller.senderRestrictionEnabled {
                    Text("Only this IP address is accepted. Nothing is accepted while it’s blank.")
                } else {
                    Text("Commands are accepted from any sender on the local network.")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("/viewtiful/next")
                    Text("/viewtiful/previous")
                    Text("/viewtiful/first")
                    Text("/viewtiful/last")
                    Text("/viewtiful/page/{page_number}")
                }
                .fontDesign(.monospaced)
                .textSelection(.enabled)
            } header: {
                Text("Commands")
            } footer: {
                Text("Page numbers follow the document’s page numbering.")
            }
        }
    }
}
