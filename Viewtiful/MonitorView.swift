import SwiftUI

struct MonitorView: View {
    @Bindable var midiController: MIDIController
    @Bindable var oscController: OSCClient
    @State private var selection = MonitorTab.midi
    @Environment(\.dismiss) private var dismiss

    private enum MonitorTab: Hashable {
        case midi
        case osc
    }

    var body: some View {
        #if os(macOS)
        tabs
            .frame(minWidth: 460, minHeight: 340)
        #else
        NavigationStack {
            tabs
                .navigationTitle("Monitors")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            MIDIMonitorView(controller: midiController)
                .tabItem { Label("MIDI", systemImage: "pianokeys") }
                .tag(MonitorTab.midi)

            OSCMonitorView(controller: oscController)
                .tabItem { Label("OSC", systemImage: "network") }
                .tag(MonitorTab.osc)
        }
    }
}

private struct MIDIMonitorView: View {
    @Bindable var controller: MIDIController

    var body: some View {
        List {
            Section("MIDI Input") {
                LabeledContent("Status", value: inputStatus)
                if let error = controller.setupError {
                    Label(error, systemImage: "exclamationmark.triangle")
                }
                LabeledContent(
                    "Connected Sources",
                    value: controller.sources.isEmpty ? "No Connected Sources" : controller.sources.map(\.name).formatted()
                )
            }

            Section("Recent Messages") {
                if controller.activityHistory.isEmpty {
                    Text("No Commands Received")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.activityHistory) { activity in
                        MIDIActivityRow(activity: activity)
                    }
                }
            }
        }
        .listStyle(.inset)
        .textSelection(.enabled)
    }

    private var inputStatus: String {
        if !controller.enabled { return "Disabled" }
        if controller.setupError != nil { return "Unavailable" }
        if controller.sources.isEmpty { return "No Connected Sources" }
        if case .source(let id) = controller.inputSelection,
           !controller.sources.contains(where: { $0.id == id }) {
            return "Selected Source Unavailable"
        }
        return "Listening"
    }
}

private struct MIDIActivityRow: View {
    let activity: MIDIActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.kind.displayName)
                    .font(.headline)
                Text(activity.source)
                    .foregroundStyle(.secondary)
                Text("Channel \(activity.channel + 1)  ·  Byte 1 \(activity.byte1)  ·  Byte 2 \(activity.byte2)")
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }

            Text(activity.received, style: .time)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OSCMonitorView: View {
    @Bindable var controller: OSCClient

    var body: some View {
        List {
            Section("Listener") {
                LabeledContent("Status", value: controller.status.label)
                LabeledContent("UDP Port", value: String(controller.port))
                if controller.localAddresses.isEmpty {
                    LabeledContent("IP Address", value: "Unavailable")
                } else {
                    ForEach(controller.localAddresses) { localAddress in
                        LabeledContent(
                            "IP Address (\(localAddress.interfaceName))",
                            value: localAddress.address
                        )
                    }
                }
                if controller.rejectedPacketCount > 0 {
                    LabeledContent("Rejected Packets", value: controller.rejectedPacketCount.formatted())
                    LabeledContent("Malformed Packets", value: controller.malformedPacketCount.formatted())
                    LabeledContent("Blocked Packets", value: controller.blockedPacketCount.formatted())
                }
            }

            Section("Recent Messages") {
                if controller.messageHistory.isEmpty {
                    Text("No Commands Received")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.messageHistory) { activity in
                        OSCActivityRow(activity: activity)
                    }
                }
            }
        }
        .listStyle(.inset)
        .textSelection(.enabled)
    }
}

private struct OSCActivityRow: View {
    let activity: OSCActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.message.address)
                    .font(.headline)
                    .fontDesign(.monospaced)
                if !activity.message.arguments.isEmpty {
                    Text(activity.message.arguments.map(\.description).joined(separator: ", "))
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
                Text("From \(activity.sender)")
                    .foregroundStyle(.secondary)
            }

            Text(activity.received, style: .time)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
