import Foundation
import CoreMIDI
import Network
import PDFKit
import AppKit
import Testing
@testable import ViewtifulCore

private final class MIDIEventResults {
    var activities: [MIDIActivity] = []
}

struct ViewtifulCoreTests {
    // Exercise Apple's event-list parser and the same decoded-message boundary as the input port.
    private func decodeMIDIEvents(_ words: [UInt32]) -> [MIDIActivity] {
        var eventList = MIDIEventList()
        let results = MIDIEventResults()
        withUnsafeMutablePointer(to: &eventList) { list in
            let packet = MIDIEventListInit(list, ._1_0)
            words.withUnsafeBufferPointer { buffer in
                _ = MIDIEventListAdd(list, MemoryLayout<MIDIEventList>.size, packet, 0, buffer.count, buffer.baseAddress!)
            }
            MIDIEventListForEachEvent(list, { context, _, message in
                let results = Unmanaged<MIDIEventResults>.fromOpaque(context!).takeUnretainedValue()
                if let activity = MIDIController.decodeMIDIMessage(message, source: "Test Source", sourceID: 123) {
                    results.activities.append(activity)
                }
            }, Unmanaged.passUnretained(results).toOpaque())
        }
        return results.activities
    }

    private func decodeMIDIWord(_ word: UInt32) -> MIDIActivity? {
        decodeMIDIEvents([word]).first
    }

    private func oscString(_ text: String) -> Data {
        var data = Data(text.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    @Test func oscCommandsAndMalformedPackets() {
        let next = oscString("/viewtiful/next") + oscString(",")
        #expect(OSCParser.parse(next)?.count == 1)
        if case .nextPage? = OSCParser.parse(next)?.first?.action {} else { Issue.record("Expected next page") }
        let page = oscString("/viewtiful/page/23") + oscString(",")
        if case .goToPage(23)? = OSCParser.parse(page)?.first?.action {} else { Issue.record("Expected page 23") }
        #expect(OSCParser.parse(oscString("/viewtiful/page/not-a-number") + oscString(","))?.first?.action == nil)
        #expect(OSCParser.parse(page.dropLast()) == nil)
        #expect(OSCParser.parse(next + Data([0])) == nil)
        #expect(OSCParser.parse(Data([255, 0, 0, 0])) == nil)
        var badPadding = oscString("/a") + oscString(",")
        badPadding[3] = 1
        #expect(OSCParser.parse(badPadding) == nil)
        for size in 0..<page.count { _ = OSCParser.parse(page.prefix(size)) }
    }

    @Test func bundlesPreserveValidElementOrder() {
        var bundle = oscString("#bundle") + Data(repeating: 0, count: 8)
        for address in ["/viewtiful/next", "/viewtiful/last"] {
            let message = oscString(address) + oscString(",")
            bundle.append(contentsOf: [0, 0, 0, UInt8(message.count)])
            bundle.append(message)
        }
        #expect(OSCParser.parse(bundle)?.map(\.address) == ["/viewtiful/next", "/viewtiful/last"])
        #expect(OSCParser.parse(bundle.dropLast()) == nil)
    }

    @Test @MainActor func oscDefaultsTo53001() throws {
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(OSCController(defaults: defaults).port == 53_001)
        #expect(OSCListenerStatus.failed("Address already in use").label == "Unavailable: Address already in use")
    }

    @Test func midiDecodingIgnoresReleaseAndOtherProtocols() {
        #expect(decodeMIDIWord(0x20903C7F)?.number == 60)
        #expect(decodeMIDIWord(0x20903C7F)?.byte2 == 127)
        #expect(decodeMIDIWord(0x20903C00) == nil)
        #expect(decodeMIDIWord(0x20803C7F) == nil)
        #expect(decodeMIDIEvents([0x40903C7F, 0]).isEmpty)
        #expect(decodeMIDIWord(0x20C00500)?.number == 5)
    }

    @Test func midiEventListDecodesAllSupportedMessagesInOrder() {
        let events = decodeMIDIEvents([0x20903C40, 0x21B2407F, 0x20CF0500, 0x20803C00])
        #expect(events.map(\.kind) == [.note, .controlChange, .programChange])
        #expect(events.map(\.channel) == [0, 2, 15])
        #expect(events.map(\.number) == [60, 64, 5])
        #expect(events.map(\.value) == [64, 127, 5])
        #expect(events.map(\.byte2) == [64, 127, 0])
        #expect(events.allSatisfy { $0.source == "Test Source" && $0.sourceID == 123 })
    }

    @Test @MainActor func legacyMidiBindingsPreservePositiveValueMatching() throws {
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = """
        ["nextPage",{"kind":"note","channel":0,"number":60},"previousPage",{"kind":"controlChange","channel":0,"number":64}]
        """
        defaults.set(Data(legacy.utf8), forKey: "midi.bindings")

        let controller = MIDIController(defaults: defaults, connectsToDevices: false)
        var actions: [ViewtifulAction] = []
        controller.onAction = { actions.append($0) }

        #expect(controller.bindings[.nextPage]?.matchesAnyByte2 == true)
        #expect(controller.bindings[.previousPage]?.matchesAnyByte2 == true)

        func send(_ word: UInt32) throws {
            controller.process(try #require(decodeMIDIWord(word)))
        }

        try send(0x20903C01) // Legacy Note binding: the smallest positive velocity.
        try send(0x20903C7F) // Legacy Note binding: the largest positive velocity.
        try send(0x20B04001) // Legacy CC binding: rising edge.
        try send(0x20B04000) // CC release rearms the edge.
        try send(0x20B0407F)

        #expect(actions.count == 4)
        #expect(controller.bindings[.nextPage]?.byte2 == 0)
        let persisted = try #require(defaults.data(forKey: "midi.bindings"))
        let migrated = try JSONDecoder().decode([MIDINavigationAction: MIDITrigger].self, from: persisted)
        #expect(migrated[.nextPage]?.matchesAnyByte2 == true)
    }

    @Test @MainActor func midiLearningAndSingleAction() throws {
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MIDIController(defaults: defaults, connectsToDevices: false)
        var actions: [ViewtifulAction] = []
        controller.onAction = { actions.append($0) }
        func send(_ word: UInt32) throws {
            controller.process(try #require(decodeMIDIWord(word)))
        }
        #expect(controller.programChangeOffset == 1)
        controller.beginLearning(.nextPage)
        try send(0x20B04000) // A pedal release must not be learned.
        #expect(controller.learningAction == .nextPage)
        try send(0x20B0407F)
        #expect(controller.learningAction == nil)
        #expect(actions.isEmpty)
        try send(0x20B0407F) // Holding the learned pedal must not advance.
        #expect(actions.isEmpty)
        try send(0x20B04000)
        try send(0x20B0407F)
        #expect(actions.count == 1)
        controller.beginLearning(.lastPage)
        try send(0x20B04000)
        try send(0x20B0407F)
        #expect(controller.bindings[.nextPage] == nil)
        controller.programChangeRecallEnabled = true
        controller.beginLearning(.firstPage)
        try send(0x20C00500)
        try send(0x20C00500)
        #expect(actions.count == 2) // Learned program wins over direct recall.
        if case .firstPage? = actions.last {} else { Issue.record("Expected first page") }
    }

    @Test @MainActor func midiBindingCapturesVelocityAndCanBeEdited() throws {
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MIDIController(defaults: defaults, connectsToDevices: false)
        var actions: [ViewtifulAction] = []
        controller.onAction = { actions.append($0) }

        func send(_ word: UInt32) throws {
            controller.process(try #require(decodeMIDIWord(word)))
        }

        controller.beginLearning(.nextPage)
        try send(0x20903C40) // Note 60, velocity 64.
        #expect(controller.bindings[.nextPage]?.channel == 0)
        #expect(controller.bindings[.nextPage]?.byte1 == 60)
        #expect(controller.bindings[.nextPage]?.byte2 == 64)

        controller.setBindingField(.nextPage, field: .byte2, value: 96)
        try send(0x20903C40)
        #expect(actions.isEmpty)
        try send(0x20903C60) // The edited velocity matches.
        #expect(actions.count == 1)

        controller.enabled = false
        try send(0x20903C60)
        #expect(actions.count == 1)
    }

    @Test @MainActor func midiBindingChangesUseCanonicalConflictRules() throws {
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MIDIController(defaults: defaults, connectsToDevices: false)

        controller.createBinding(.nextPage, kind: .note, channel: 1, byte1: 60, byte2: 64)
        controller.createBinding(.previousPage, kind: .note, channel: 1, byte1: 60, byte2: 64)
        #expect(controller.bindings[.nextPage] == nil)
        #expect(controller.bindings[.previousPage]?.byte2 == 64)

        controller.createBinding(.firstPage, kind: .programChange, channel: 1, byte1: 5, byte2: 0)
        controller.createBinding(.lastPage, kind: .programChange, channel: 1, byte1: 5, byte2: 127)
        #expect(controller.bindings[.firstPage] == nil)
        #expect(controller.bindings[.lastPage]?.byte1 == 5)

        controller.createBinding(.nextPage, kind: .note, channel: 1, byte1: 61, byte2: 64)
        controller.setBindingField(.nextPage, field: .byte1, value: 60)
        #expect(controller.bindings[.previousPage] == nil)
        #expect(controller.bindings[.nextPage]?.byte1 == 60)
    }

    @Test @MainActor func controlChangeEdgesUseBindingAndSourceIdentity() throws {
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MIDIController(defaults: defaults, connectsToDevices: false)
        controller.createBinding(.nextPage, kind: .controlChange, channel: 1, byte1: 64, byte2: 127)
        var actions: [ViewtifulAction] = []
        controller.onAction = { actions.append($0) }

        func send(sourceID: Int32, value: UInt8) {
            controller.process(MIDIActivity(source: "Same Name", sourceID: sourceID, channel: 0,
                                             kind: .controlChange, byte1: 64, byte2: value, received: .now))
        }

        send(sourceID: 101, value: 1) // A nonmatching value must not arm the binding.
        send(sourceID: 101, value: 127)
        send(sourceID: 101, value: 127) // Still held.
        send(sourceID: 101, value: 0)
        send(sourceID: 101, value: 127)
        send(sourceID: 202, value: 127) // Same display name, different source.

        #expect(actions.count == 3)
    }

    @Test @MainActor func oscReceivesAfterRestartAndIgnoresStoppedInput() async throws {
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = OSCController(defaults: defaults)
        // Private loopback test port; no application preferences are touched.
        controller.port = Int.random(in: 55000...64000)
        controller.setAvailable(true)
        defer { controller.stop() }
        for _ in 0..<100 {
            if controller.status.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.status.isRunning)
        var count = 0
        controller.onAction = { _ in count += 1 }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(controller.port))!, using: .udp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        let packet = oscString("/viewtiful/next") + oscString(",")
        connection.send(content: packet, completion: .contentProcessed { _ in })
        for _ in 0..<100 {
            if count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(count == 1)
        controller.stop()
        connection.send(content: packet, completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(100))
        #expect(count == 1)
        controller.setAvailable(true)
        for _ in 0..<100 {
            if controller.status.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.status.isRunning)
        connection.send(content: packet, completion: .contentProcessed { _ in })
        for _ in 0..<100 {
            if count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(count == 2)
    }

    @Test func scrollGesturesTurnOnceAndIgnoreMomentum() {
        var scroll = ScrollPageNavigation()
        #expect(scroll.action(delta: -12, precise: true, began: true, ended: false, momentum: false, timestamp: 1) == nil)
        if case .nextPage? = scroll.action(delta: -15, precise: true, began: false, ended: false, momentum: false, timestamp: 1.01) {} else { Issue.record("Expected next page") }
        #expect(scroll.action(delta: -80, precise: true, began: false, ended: false, momentum: false, timestamp: 1.02) == nil)
        #expect(scroll.action(delta: -80, precise: true, began: false, ended: false, momentum: true, timestamp: 1.5) == nil)
        if case .previousPage? = scroll.action(delta: 30, precise: true, began: true, ended: false, momentum: false, timestamp: 2) {} else { Issue.record("Expected previous page") }
        #expect(scroll.action(delta: 30, precise: true, began: false, ended: true, momentum: false, timestamp: 2.1) == nil)
    }

    @Test func discreteWheelDebouncesAndRearms() {
        var scroll = ScrollPageNavigation()
        if case .nextPage? = scroll.action(delta: -1, precise: false, began: false, ended: false, momentum: false, timestamp: 1) {} else { Issue.record("Expected wheel turn") }
        #expect(scroll.action(delta: -1, precise: false, began: false, ended: false, momentum: false, timestamp: 1.01) == nil)
        if case .previousPage? = scroll.action(delta: 1, precise: false, began: false, ended: false, momentum: false, timestamp: 1.3) {} else { Issue.record("Expected reverse wheel turn") }
    }

    @Test @MainActor func navigationAndRestoration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = PDFDocument()
        for index in 0..<3 {
            let image = NSImage(size: NSSize(width: 200, height: 300), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                return true
            }
            pdf.insert(try #require(PDFPage(image: image)), at: index)
        }
        let source = root.appendingPathComponent("Test.pdf")
        #expect(pdf.write(to: source))
        let storage = root.appendingPathComponent("Library")
        let model = ViewerModel(defaults: defaults, storageDirectory: storage)
        model.importDocument(from: source)
        #expect(model.pageCount == 3)
        model.perform(.previousPage)
        #expect(model.displayedPageNumber == 3)
        model.perform(.nextPage)
        #expect(model.displayedPageNumber == 1)
        model.perform(.goToPage(0))
        model.perform(.goToPage(4))
        #expect(model.displayedPageNumber == 1)
        model.perform(.goToPage(2))
        model.flushPendingPersistence()
        let restored = ViewerModel(defaults: defaults, storageDirectory: storage)
        #expect(restored.displayedPageNumber == 2)
        restored.removeDocument(try #require(restored.activeDocument))
        #expect(!restored.hasDocument)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test @MainActor func edgeTapNavigationPreferenceDefaultsOnAndPersists() throws {
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = ViewerModel(defaults: defaults)
        #expect(model.edgeTapNavigationEnabled)

        model.edgeTapNavigationEnabled = false
        let restored = ViewerModel(defaults: defaults)
        #expect(!restored.edgeTapNavigationEnabled)
    }

    @Test @MainActor func damagedLibraryIsPreservedUntilExplicitRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ViewtifulTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        let storage = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let libraryURL = storage.appendingPathComponent("Library.json")
        let damagedData = Data("not valid library metadata".utf8)
        try damagedData.write(to: libraryURL)

        let model = ViewerModel(defaults: defaults, storageDirectory: storage)
        #expect(model.documents.isEmpty)
        #expect(model.libraryNeedsRecovery)
        let recoveryURL = try #require(model.libraryRecoveryURL)
        #expect(FileManager.default.fileExists(atPath: recoveryURL.path))
        #expect(try Data(contentsOf: recoveryURL) == damagedData)

        model.importDocument(from: root.appendingPathComponent("not-a-pdf.pdf"))
        #expect(model.libraryNeedsRecovery)
        #expect(try Data(contentsOf: libraryURL) == damagedData)

        model.startNewLibrary()
        #expect(!model.libraryNeedsRecovery)
        let recovered = try JSONDecoder().decode([ShowDocument].self, from: Data(contentsOf: libraryURL))
        #expect(recovered.isEmpty)
        #expect(FileManager.default.fileExists(atPath: recoveryURL.path))
    }
}
