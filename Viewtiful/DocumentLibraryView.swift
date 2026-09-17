import SwiftUI

struct DocumentLibraryView: View {
    @Bindable var model: ViewerModel
    @Binding var isImporting: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var documentPendingRemoval: ShowDocument?

    var body: some View {
        NavigationStack {
            Group {
                if model.documents.isEmpty {
                    ContentUnavailableView {
                        Label("No Documents", systemImage: "doc.richtext")
                    } description: {
                        Text("Imported PDFs are stored locally for reliable show use.")
                    } actions: {
                        Button("Import PDF", systemImage: "plus") {
                            isImporting = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(model.documents) { document in
                        DocumentRow(
                            document: document,
                            isActive: document.id == model.activeDocumentID,
                            openAction: {
                                model.selectDocument(document)
                                if model.activeDocumentID == document.id {
                                    dismiss()
                                }
                            },
                            removeAction: {
                                documentPendingRemoval = document
                            }
                        )
                    }
                }
            }
            .navigationTitle("Documents")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Import PDF", systemImage: "plus") {
                        isImporting = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove Document?",
            isPresented: Binding(
                get: { documentPendingRemoval != nil },
                set: { if !$0 { documentPendingRemoval = nil } }
            ),
            presenting: documentPendingRemoval
        ) { document in
            Button("Remove \(document.displayName)", role: .destructive) {
                model.removeDocument(document)
                documentPendingRemoval = nil
            }
        } message: { document in
            Text("\(document.displayName) will be removed from Viewtiful. The original file is not affected.")
        }
    }
}

private struct MIDISettingsSection: View {
    @Bindable var controller: MIDIController

    var body: some View {
        Section("MIDI") {
            if let setupError = controller.setupError {
                Label(setupError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if controller.sources.isEmpty {
                LabeledContent("Inputs", value: "No Sources")
            } else {
                LabeledContent("Inputs") {
                    Text(controller.sources.map(\.name).formatted(.list(type: .and)))
                        .multilineTextAlignment(.trailing)
                }
            }

            Picker("Channel", selection: $controller.channelFilter) {
                Text("Any").tag(0)
                ForEach(1...16, id: \.self) { channel in
                    Text("Channel \(channel)").tag(channel)
                }
            }

            ForEach(MIDINavigationAction.allCases) { action in
                LabeledContent(action.title) {
                    HStack {
                        if controller.learningAction == action {
                            Text("Listening…")
                                .foregroundStyle(.secondary)
                            Button("Cancel") {
                                controller.cancelLearning()
                            }
                        } else {
                            Text(controller.bindings[action]?.description ?? "Not Learned")
                                .foregroundStyle(.secondary)
                            Button("Learn") {
                                controller.beginLearning(action)
                            }
                            if controller.bindings[action] != nil {
                                Button("Clear", role: .destructive) {
                                    controller.clearBinding(action)
                                }
                            }
                        }
                    }
                }
            }

            Toggle("Program Change Page Recall", isOn: $controller.programChangeRecallEnabled)

            if controller.programChangeRecallEnabled {
                Stepper(
                    "Page Offset: \(controller.programChangeOffset)",
                    value: $controller.programChangeOffset,
                    in: -127...128
                )
                Text("Page = Program + Offset. Use offset 1 for Program 0 → Page 1.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let activity = controller.lastActivity {
                LabeledContent("Last Message") {
                    Text(activity.description)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Received") {
                    Text(activity.received, style: .time)
                }
            }
        }
    }
}

private struct DocumentRow: View {
    let document: ShowDocument
    let isActive: Bool
    let openAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        Button(action: openAction) {
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text("\(document.pageCount) pages · Last viewed page \(document.lastPageIndex + 1)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Active document")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive) {
                removeAction()
            }
        }
        .contextMenu {
            Button("Remove", systemImage: "trash", role: .destructive) {
                removeAction()
            }
        }
        .accessibilityHint(isActive ? "Currently open" : "Opens this document")
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: ViewerModel
    @Bindable var oscController: OSCController
    @Bindable var midiController: MIDIController
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView {
                Tab("General", systemImage: "gearshape") {
                    GeneralSettingsForm(model: model)
                }

                Tab("MIDI", systemImage: "pianokeys") {
                    Form {
                        MIDISettingsSection(controller: midiController)
                    }
                }

                Tab("OSC", systemImage: "network") {
                    OSCSettingsForm(controller: oscController)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
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

            Section("Performance") {
                Toggle("Keep Screen Awake", isOn: $model.keepScreenAwake)

                Text("Prevents sleep only while a document is open and Viewtiful is active.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OSCSettingsForm: View {
    @Bindable var controller: OSCController

    var body: some View {
        Form {
            Section("Listener") {
                Toggle("OSC Enabled", isOn: $controller.enabled)

                HStack {
                    TextField("UDP Listen Port", value: $controller.port, format: .number)
                    Button("Apply") {
                        controller.applyConfiguration()
                    }
                    .disabled(!(1...65_535).contains(controller.port))
                }

                LabeledContent("Status", value: controller.status.label)
            }

            Section("Last Message") {
                if let message = controller.lastMessage {
                    LabeledContent("Address", value: message.address)
                    LabeledContent(
                        "Arguments",
                        value: message.arguments.map(\.description).joined(separator: ", ")
                    )
                } else {
                    Text("No OSC messages received.")
                        .foregroundStyle(.secondary)
                }

                if !controller.lastSender.isEmpty {
                    LabeledContent("Sender", value: controller.lastSender)
                }

                if let received = controller.lastReceived {
                    LabeledContent("Received") {
                        Text(received, style: .time)
                    }
                }

                if controller.rejectedPacketCount > 0 {
                    LabeledContent(
                        "Rejected Packets",
                        value: controller.rejectedPacketCount.formatted()
                    )
                }
            }

            Section("Commands") {
                Text("/viewtiful/next")
                Text("/viewtiful/previous")
                Text("/viewtiful/first")
                Text("/viewtiful/last")
                Text("/viewtiful/page 23")
            }
            .fontDesign(.monospaced)
        }
    }
}
