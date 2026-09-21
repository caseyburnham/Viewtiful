import SwiftUI

/// One show-control message as it arrived, paired with what Viewtiful made of
/// it. Recording the outcome alongside the message is what lets an operator
/// tell "nothing arrived" apart from "something arrived and was refused".
nonisolated struct ActivityEntry: Identifiable, Hashable, Sendable {
    enum Source: String, CaseIterable, Hashable, Sendable {
        case midi
        case osc

        var label: String {
            switch self {
            case .midi: "MIDI"
            case .osc: "OSC"
            }
        }

        var systemImage: String {
            switch self {
            case .midi: "pianokeys"
            case .osc: "network"
            }
        }
    }

    enum Status: Hashable, Sendable {
        /// The message turned a page or captured a mapping.
        case triggered(String)
        /// Understood, but there was nothing for it to do.
        case ignored(String)
        /// Received and unusable: the case worth spotting from across a room.
        case invalid(String)

        var systemImage: String {
            switch self {
            case .triggered: "checkmark.circle.fill"
            case .ignored: "arrow.down.circle.fill"
            case .invalid: "xmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .triggered: .green
            case .ignored: .secondary
            case .invalid: .red
            }
        }

        /// The outcome in a few words, shown in the Result column.
        var label: String {
            switch self {
            case .triggered(let action): action
            case .ignored(let reason): reason
            case .invalid(let reason): reason
            }
        }

        var title: String {
            switch self {
            case .triggered: "Triggered"
            case .ignored: "Ignored"
            case .invalid: "Invalid"
            }
        }

        var isInvalid: Bool {
            if case .invalid = self { return true }
            return false
        }
    }

    let id = UUID()
    let timestamp: Date
    let source: Source
    let status: Status
    /// The message itself: an OSC address, or a named MIDI message.
    let message: String
    /// Everything else the message carried.
    let details: String
    /// The sender's IP address, or the MIDI source's name.
    let origin: String

    /// Lowercased once here so filtering does not renormalise every retained
    /// entry on each keystroke or each new message.
    private let searchableText: String

    init(
        timestamp: Date = .now,
        source: Source,
        status: Status,
        message: String,
        details: String = "",
        origin: String
    ) {
        self.timestamp = timestamp
        self.source = source
        self.status = status
        self.message = message
        self.details = details
        self.origin = origin
        searchableText = "\(message) \(details) \(origin) \(status.label)".lowercased()
    }

    var sourceName: String { source.label }
    var result: String { status.label }

    /// `query` is expected to be lowercased already, so a filter pass
    /// normalises the search text once rather than once per entry.
    func matches(lowercasedQuery query: String) -> Bool {
        query.isEmpty || searchableText.contains(query)
    }

    var copyableDescription: String {
        let time = Self.clipboardFormatter.string(from: timestamp)
        let parts = [time, source.label, message, details, "(\(status.label))"]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let clipboardFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// The rows the Activity Log window shows. Rows stop arriving while the log is
/// paused and are dropped when it is cleared; the session totals keep counting
/// either way, so the status bar stays honest about what reached the app.
@MainActor
@Observable
final class ActivityLog {
    let capacity: Int

    private(set) var entries: [ActivityEntry] = []
    private(set) var totalMIDI = 0
    private(set) var totalOSC = 0
    private(set) var totalInvalid = 0

    var isPaused = false

    init(capacity: Int = 500) {
        self.capacity = max(0, capacity)
    }

    func record(_ entry: ActivityEntry) {
        switch entry.source {
        case .midi: totalMIDI += 1
        case .osc: totalOSC += 1
        }
        if entry.status.isInvalid { totalInvalid += 1 }

        guard !isPaused, capacity > 0 else { return }

        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

extension ViewtifulAction {
    /// How the action reads in the log's Result column.
    var title: String {
        switch self {
        case .nextPage: "Next Page"
        case .previousPage: "Previous Page"
        case .firstPage: "First Page"
        case .lastPage: "Last Page"
        case .goToPage(let page): "Go to PDF Page \(page)"
        case .goToLabeledPage(let page): "Go to Page \(page)"
        }
    }
}
