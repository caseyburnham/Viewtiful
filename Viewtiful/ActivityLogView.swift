#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Holds the log window's filter state and turns the log's entries into the
/// rows it shows.
@MainActor
@Observable
final class ActivityLogPresenter {
    enum Filter: String, CaseIterable, Identifiable {
        case all, midi, osc, invalid

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .midi: "MIDI"
            case .osc: "OSC"
            case .invalid: "Invalid"
            }
        }

        func matches(_ entry: ActivityEntry) -> Bool {
            switch self {
            case .all: true
            case .midi: entry.source == .midi
            case .osc: entry.source == .osc
            case .invalid: entry.status.isInvalid
            }
        }
    }

    struct Snapshot {
        let allEntries: [ActivityEntry]
        let filteredEntries: [ActivityEntry]
        let query: String
        let isFiltered: Bool
    }

    var searchText = ""
    var filter: Filter = .all
    var sortOrder = [KeyPathComparator(\ActivityEntry.timestamp, order: .reverse)]

    func snapshot(of log: ActivityLog) -> Snapshot {
        let allEntries = log.entries
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filteredEntries = allEntries
            .filter { filter.matches($0) && $0.matches(lowercasedQuery: query) }
            .sorted(using: sortOrder)

        return Snapshot(
            allEntries: allEntries,
            filteredEntries: filteredEntries,
            query: query,
            isFiltered: filter != .all || !query.isEmpty
        )
    }
}

struct ActivityLogView: View {
    @Bindable var log: ActivityLog

    @State private var presenter = ActivityLogPresenter()
    @State private var selection: Set<ActivityEntry.ID> = []
    @State private var isShowingInspector = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let snapshot = presenter.snapshot(of: log)

        #if os(macOS)
        table(for: snapshot)
            .frame(minWidth: 620, minHeight: 360)
        #else
        NavigationStack {
            list(for: snapshot)
                .navigationTitle("Activity Log")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $presenter.searchText, prompt: "Filter by message or sender")
                .safeAreaInset(edge: .bottom) { statusBar(for: snapshot) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { optionsMenu(for: snapshot) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #endif
    }

#if os(macOS)
    private func table(for snapshot: ActivityLogPresenter.Snapshot) -> some View {
        Table(snapshot.filteredEntries, selection: $selection, sortOrder: $presenter.sortOrder) {
            TableColumn("") { entry in
                Image(systemName: entry.status.systemImage)
                    .foregroundStyle(entry.status.tint)
                    .help("\(entry.status.title): \(entry.status.label)")
                    .accessibilityLabel("\(entry.status.title), \(entry.status.label)")
            }
            .width(24)

            TableColumn("Time", value: \.timestamp) { entry in
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80, max: 110)

            TableColumn("Source", value: \.sourceName) { entry in
                Label(entry.source.label, systemImage: entry.source.systemImage)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 72, max: 90)

            TableColumn("Message", value: \.message) { entry in
                Text(entry.message)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 150, ideal: 220)

            TableColumn("Details", value: \.details) { entry in
                Text(entry.details)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Result", value: \.result) { entry in
                Text(entry.result)
                    .foregroundStyle(entry.status.isInvalid ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 100, ideal: 150)
        }
        .overlay { emptyState(for: snapshot) }
        .copyable(copyableLines(for: selection, in: snapshot.filteredEntries))
        .contextMenu(forSelectionType: ActivityEntry.ID.self) { ids in
            if ids.count == 1 {
                Button("Show Message") { isShowingInspector = true }
            }
            Button(ids.count > 1 ? "Copy \(ids.count) Messages" : "Copy Message") {
                copy(ids, in: snapshot.filteredEntries)
            }
            .disabled(ids.isEmpty)
        } primaryAction: { ids in
            guard ids.count == 1 else { return }
            isShowingInspector = true
        }
        .inspector(isPresented: $isShowingInspector) {
            messageInspector(for: snapshot)
        }
        .searchable(text: $presenter.searchText, prompt: "Filter by message or sender")
        .safeAreaInset(edge: .bottom) { statusBar(for: snapshot) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $presenter.filter) {
                    ForEach(ActivityLogPresenter.Filter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            ToolbarItem {
                Button {
                    log.isPaused.toggle()
                } label: {
                    Label(
                        log.isPaused ? "Resume" : "Pause",
                        systemImage: log.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .help(log.isPaused
                    ? "Resume recording. Counters kept advancing while paused."
                    : "Stop adding rows so you can read them. Counters keep advancing.")
            }

            ToolbarItem {
                Button {
                    log.clear()
                    selection.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(snapshot.allEntries.isEmpty)
                .help("Discard the recorded rows. Counters are unaffected.")
            }

            ToolbarItem {
                Toggle(isOn: $isShowingInspector) {
                    Label("Message", systemImage: "sidebar.right")
                }
                .help("Show the selected message in full")
            }
        }
    }

    @ViewBuilder
    private func messageInspector(for snapshot: ActivityLogPresenter.Snapshot) -> some View {
        Group {
            if let entry = inspectedEntry(in: snapshot.filteredEntries) {
                Form {
                    Section {
                        LabeledContent("Status") {
                            Label(entry.status.title, systemImage: entry.status.systemImage)
                                .foregroundStyle(entry.status.tint)
                        }
                        LabeledContent("Result", value: entry.status.label)
                        LabeledContent("Source") {
                            Label(entry.source.label, systemImage: entry.source.systemImage)
                        }
                        LabeledContent("From", value: entry.origin)
                        LabeledContent("Time") {
                            Text(entry.timestamp, format: .dateTime
                                .hour().minute().second().secondFraction(.fractional(3)))
                                .monospacedDigit()
                        }
                    }

                    Section("Message") {
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !entry.details.isEmpty {
                        Section("Details") {
                            Text(entry.details)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "No Message Selected",
                    systemImage: "text.viewfinder",
                    description: Text(selection.count > 1
                        ? "Select a single row to see it in full."
                        : "Select a row to see everything it carried.")
                )
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 340, max: 640)
    }

    private func inspectedEntry(in entries: [ActivityEntry]) -> ActivityEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return entries.first { $0.id == id }
    }

    private func copyableLines(
        for ids: Set<ActivityEntry.ID>, in entries: [ActivityEntry]
    ) -> [String] {
        entries
            .filter { ids.contains($0.id) }
            .map(\.copyableDescription)
    }

    private func copy(_ ids: Set<ActivityEntry.ID>, in entries: [ActivityEntry]) {
        let lines = copyableLines(for: ids, in: entries)
        guard !lines.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
#else
    private func list(for snapshot: ActivityLogPresenter.Snapshot) -> some View {
        List(snapshot.filteredEntries) { entry in
            ActivityEntryRow(entry: entry)
        }
        .listStyle(.inset)
        .textSelection(.enabled)
        .overlay { emptyState(for: snapshot) }
    }

    private func optionsMenu(for snapshot: ActivityLogPresenter.Snapshot) -> some View {
        Menu {
            Picker("Show", selection: $presenter.filter) {
                ForEach(ActivityLogPresenter.Filter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.inline)

            Section {
                Button(
                    log.isPaused ? "Resume" : "Pause",
                    systemImage: log.isPaused ? "play.fill" : "pause.fill"
                ) {
                    log.isPaused.toggle()
                }

                Button("Clear", systemImage: "trash", role: .destructive) {
                    log.clear()
                }
                .disabled(snapshot.allEntries.isEmpty)
            }
        } label: {
            Label("Log Options", systemImage: "line.3.horizontal.decrease.circle")
        }
    }
#endif

    @ViewBuilder
    private func emptyState(for snapshot: ActivityLogPresenter.Snapshot) -> some View {
        if snapshot.allEntries.isEmpty {
            ContentUnavailableView(
                "No Activity",
                systemImage: "list.bullet.rectangle",
                description: Text("MIDI and OSC messages appear here as they arrive.")
            )
        } else if snapshot.filteredEntries.isEmpty {
            if snapshot.query.isEmpty {
                ContentUnavailableView(
                    "No \(presenter.filter.title) Messages",
                    systemImage: "line.3.horizontal.decrease",
                    description: Text("Nothing in the log matches this filter.")
                )
            } else {
                ContentUnavailableView.search(text: presenter.searchText)
            }
        }
    }

    private func statusBar(for snapshot: ActivityLogPresenter.Snapshot) -> some View {
        HStack(spacing: 16) {
            total(log.totalMIDI, systemImage: ActivityEntry.Source.midi.systemImage,
                  tint: .secondary, label: "MIDI messages")
            total(log.totalOSC, systemImage: ActivityEntry.Source.osc.systemImage,
                  tint: .secondary, label: "OSC messages")
            if log.totalInvalid > 0 {
                total(log.totalInvalid, systemImage: "xmark.circle.fill",
                      tint: .red, label: "invalid messages")
            }

            Spacer()

            if snapshot.isFiltered {
                Text("\(snapshot.filteredEntries.count) of \(snapshot.allEntries.count) shown")
                    .foregroundStyle(.secondary)
            }

            if log.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func total(_ count: Int, systemImage: String, tint: Color, label: String) -> some View {
        Label {
            Text(count, format: .number)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .help("\(label.capitalized) this session")
        .accessibilityLabel("\(count) \(label)")
    }
}

#if !os(macOS)
private struct ActivityEntryRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.status.systemImage)
                .foregroundStyle(entry.status.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.message)
                    .font(.headline)
                    .fontDesign(.monospaced)
                if !entry.details.isEmpty {
                    Text(entry.details)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
                Text("\(entry.source.label) · \(entry.origin)")
                    .foregroundStyle(.secondary)
                Text(entry.status.label)
                    .foregroundStyle(entry.status.isInvalid ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }

            Spacer(minLength: 8)

            Text(entry.timestamp, style: .time)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.status.title), \(entry.source.label), \(entry.message), \(entry.status.label)")
    }
}
#endif

#Preview {
    let log = ActivityLog()
    log.record(ActivityEntry(
        source: .osc, status: .triggered("Next Page"),
        message: "/viewtiful/next", origin: "10.0.1.42"
    ))
    log.record(ActivityEntry(
        source: .osc, status: .invalid("Not a Viewtiful command"),
        message: "/viewtiful/pge/12", origin: "10.0.1.42"
    ))
    log.record(ActivityEntry(
        source: .midi, status: .ignored("No mapping"),
        message: "Note On 60", details: "Channel 1 · Byte 1 60 · Byte 2 127",
        origin: "Launchpad"
    ))
    return ActivityLogView(log: log)
        .frame(width: 820, height: 480)
}
