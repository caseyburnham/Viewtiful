import Foundation
import Observation
import PDFKit

enum ViewtifulAction: Sendable {
    case nextPage
    case previousPage
    case goToPage(Int)
    case firstPage
    case lastPage
}

enum StartupBehavior: String, CaseIterable, Identifiable, Sendable {
    case firstPage
    case resumeLastPage

    var id: Self { self }
}

struct ShowDocument: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let storedFilename: String
    let pageCount: Int
    var lastPageIndex: Int
    var lastOpened: Date
}

@MainActor
@Observable
final class ViewerModel {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageDirectory: URL?
    @ObservationIgnored private var pendingPersistenceTask: Task<Void, Never>?

    private(set) var document: PDFDocument?
    private(set) var activeDocumentID: ShowDocument.ID?
    private(set) var currentPageIndex = 0
    private(set) var documents: [ShowDocument] = []
    private(set) var presentedError: String?
    private(set) var libraryNeedsRecovery = false
    private(set) var libraryRecoveryURL: URL?

    var startupBehavior: StartupBehavior {
        didSet {
            defaults.set(startupBehavior.rawValue, forKey: Keys.startupBehavior)
        }
    }

    var keepScreenAwake: Bool {
        didSet {
            defaults.set(keepScreenAwake, forKey: Keys.keepScreenAwake)
        }
    }

    var invertPDFColors: Bool {
        didSet { defaults.set(invertPDFColors, forKey: "invertPDFColors") }
    }

    var invertAnnotations: Bool {
        didSet { defaults.set(invertAnnotations, forKey: "invertAnnotations") }
    }

    var edgeTapNavigationEnabled: Bool {
        didSet { defaults.set(edgeTapNavigationEnabled, forKey: Keys.edgeTapNavigationEnabled) }
    }

    var pageCount: Int {
        document?.pageCount ?? 0
    }

    var displayedPageNumber: Int {
        pageCount == 0 ? 0 : currentPageIndex + 1
    }

    var hasDocument: Bool {
        document != nil
    }

    var documentName: String {
        activeDocument?.displayName ?? ""
    }

    var activeDocument: ShowDocument? {
        guard let activeDocumentID else { return nil }
        return documents.first { $0.id == activeDocumentID }
    }

    init(defaults: UserDefaults = .standard, storageDirectory: URL? = nil) {
        self.defaults = defaults
        self.storageDirectory = storageDirectory
        let savedBehavior = defaults.string(forKey: Keys.startupBehavior)
        startupBehavior = StartupBehavior(rawValue: savedBehavior ?? "") ?? .resumeLastPage

        if defaults.object(forKey: Keys.keepScreenAwake) == nil {
            keepScreenAwake = true
        } else {
            keepScreenAwake = defaults.bool(forKey: Keys.keepScreenAwake)
        }

        invertPDFColors = defaults.bool(forKey: "invertPDFColors")
        invertAnnotations = defaults.bool(forKey: "invertAnnotations")
        if defaults.object(forKey: Keys.edgeTapNavigationEnabled) == nil {
            edgeTapNavigationEnabled = true
        } else {
            edgeTapNavigationEnabled = defaults.bool(forKey: Keys.edgeTapNavigationEnabled)
        }

        loadLibrary()
        restoreLastDocument()
    }

    deinit {
        pendingPersistenceTask?.cancel()
    }

    func perform(_ action: ViewtifulAction) {
        guard pageCount > 0 else { return }
        let previousPageIndex = currentPageIndex

        switch action {
        case .nextPage:
            currentPageIndex = (currentPageIndex + 1) % pageCount
        case .previousPage:
            currentPageIndex = (currentPageIndex - 1 + pageCount) % pageCount
        case .goToPage(let pageNumber):
            guard (1...pageCount).contains(pageNumber) else { return }
            currentPageIndex = pageNumber - 1
        case .firstPage:
            currentPageIndex = 0
        case .lastPage:
            currentPageIndex = pageCount - 1
        }

        guard currentPageIndex != previousPageIndex else { return }
        persistCurrentPage()
    }

    func importDocument(from sourceURL: URL) {
        presentedError = nil
        guard !libraryNeedsRecovery else {
            presentedError = libraryRecoveryMessage
            return
        }
        cancelPendingPersistence()
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let id = UUID()
            let storedFilename = "\(id.uuidString).pdf"
            let destinationURL = try documentsDirectory()
                .appendingPathComponent(storedFilename)

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            guard let loadedDocument = PDFDocument(url: destinationURL), !loadedDocument.isLocked, loadedDocument.pageCount > 0 else {
                try? FileManager.default.removeItem(at: destinationURL)
                throw ViewerError.invalidPDF
            }

            let record = ShowDocument(
                id: id,
                displayName: sourceURL.deletingPathExtension().lastPathComponent,
                storedFilename: storedFilename,
                pageCount: loadedDocument.pageCount,
                lastPageIndex: 0,
                lastOpened: .now
            )
            documents.append(record)
            open(record, loadedDocument: loadedDocument)
        } catch {
            presentedError = "The selected PDF could not be imported."
        }
    }

    func selectDocument(_ document: ShowDocument) {
        cancelPendingPersistence()
        do {
            try openDocument(document)
        } catch {
            presentedError = "The selected PDF can no longer be opened."
        }
    }

    func removeDocument(_ documentToRemove: ShowDocument) {
        cancelPendingPersistence()
        let wasActive = activeDocumentID == documentToRemove.id

        do {
            let url = try url(for: documentToRemove)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            documents.removeAll { $0.id == documentToRemove.id }
            saveLibrary()

            if wasActive {
                document = nil
                activeDocumentID = nil
                currentPageIndex = 0
                defaults.removeObject(forKey: Keys.lastDocumentID)
            }
        } catch {
            presentedError = "The document could not be removed."
        }
    }

    func reportImportError(_ error: Error) {
        guard (error as NSError).code != NSUserCancelledError else { return }
        presentedError = "The PDF could not be imported. \(error.localizedDescription)"
    }

    func clearPresentedError() {
        presentedError = nil
    }

    /// Writes the latest page position immediately. Call this at lifecycle
    /// boundaries where queued persistence must be complete before suspension.
    func flushPendingPersistence() {
        cancelPendingPersistence()
        saveLibrary()
    }

    func startNewLibrary() {
        guard libraryNeedsRecovery else { return }
        guard libraryRecoveryURL != nil else {
            presentedError = "Viewtiful could not preserve the damaged document library, so it cannot safely create a new one."
            return
        }

        documents = []
        libraryNeedsRecovery = false
        guard saveLibrary() else {
            libraryNeedsRecovery = true
            return
        }
        presentedError = nil
    }

    private func openDocument(_ record: ShowDocument) throws {
        let documentURL = try url(for: record)
        guard
            FileManager.default.fileExists(atPath: documentURL.path),
            let loadedDocument = PDFDocument(url: documentURL),
            !loadedDocument.isLocked, loadedDocument.pageCount > 0
        else {
            throw ViewerError.invalidPDF
        }

        open(record, loadedDocument: loadedDocument)
    }

    private func open(_ record: ShowDocument, loadedDocument: PDFDocument) {
        cancelPendingPersistence()
        document = loadedDocument
        activeDocumentID = record.id

        let restoredPage = startupBehavior == .resumeLastPage ? record.lastPageIndex : 0
        currentPageIndex = min(max(restoredPage, 0), loadedDocument.pageCount - 1)

        updateRecord(record.id) {
            $0.lastOpened = .now
            $0.lastPageIndex = currentPageIndex
        }
        defaults.set(record.id.uuidString, forKey: Keys.lastDocumentID)
        sortLibrary()
        saveLibrary()
    }

    private func restoreLastDocument() {
        guard
            let idString = defaults.string(forKey: Keys.lastDocumentID),
            let id = UUID(uuidString: idString),
            let record = documents.first(where: { $0.id == id })
        else {
            return
        }

        do {
            try openDocument(record)
        } catch {
            defaults.removeObject(forKey: Keys.lastDocumentID)
        }
    }

    private func persistCurrentPage() {
        guard let activeDocumentID else { return }
        updateRecord(activeDocumentID) {
            $0.lastPageIndex = currentPageIndex
        }
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.saveLibrary()
            self.pendingPersistenceTask = nil
        }
    }

    private func cancelPendingPersistence() {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
    }

    private func updateRecord(_ id: ShowDocument.ID, update: (inout ShowDocument) -> Void) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        update(&documents[index])
    }

    private func loadLibrary() {
        let libraryFileURL: URL
        do {
            libraryFileURL = try libraryURL()
            guard FileManager.default.fileExists(atPath: libraryFileURL.path) else {
                documents = []
                return
            }

            let data = try Data(contentsOf: libraryFileURL)
            documents = try JSONDecoder().decode([ShowDocument].self, from: data)
            documents.removeAll { record in
                guard let recordURL = try? url(for: record) else { return true }
                return !FileManager.default.fileExists(atPath: recordURL.path)
            }
            sortLibrary()
            saveLibrary()
        } catch {
            documents = []
            libraryNeedsRecovery = true
            libraryRecoveryURL = preserveDamagedLibrary(at: (try? libraryURL()))
            presentedError = libraryRecoveryMessage
        }
    }

    @discardableResult
    private func saveLibrary() -> Bool {
        do {
            let data = try JSONEncoder().encode(documents)
            try data.write(to: libraryURL(), options: .atomic)
            return true
        } catch {
            presentedError = "Viewtiful could not save the document library."
            return false
        }
    }

    private var libraryRecoveryMessage: String {
        if let libraryRecoveryURL {
            return "Viewtiful could not read its document library. The damaged metadata was preserved at \(libraryRecoveryURL.path). Choose “Start New Library” only after recovering that file."
        }
        return "Viewtiful could not read its document library, and could not preserve a recovery copy. No library changes were made."
    }

    private func preserveDamagedLibrary(at url: URL?) -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let recoveryURL = url.deletingLastPathComponent()
            .appendingPathComponent("Library.corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.copyItem(at: url, to: recoveryURL)
            return recoveryURL
        } catch {
            return nil
        }
    }

    private func sortLibrary() {
        documents.sort {
            if $0.lastOpened != $1.lastOpened {
                return $0.lastOpened > $1.lastOpened
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func url(for record: ShowDocument) throws -> URL {
        try documentsDirectory().appendingPathComponent(record.storedFilename)
    }

    private func libraryURL() throws -> URL {
        try applicationDirectory().appendingPathComponent("Library.json")
    }

    private func documentsDirectory() throws -> URL {
        let directory = try applicationDirectory().appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func applicationDirectory() throws -> URL {
        if let storageDirectory {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            return storageDirectory
        }
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = baseURL.appendingPathComponent("Viewtiful", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private enum Keys {
        static let lastDocumentID = "lastDocumentID"
        static let startupBehavior = "startupBehavior"
        static let keepScreenAwake = "keepScreenAwake"
        static let edgeTapNavigationEnabled = "edgeTapNavigationEnabled"
    }

    private enum ViewerError: Error {
        case invalidPDF
    }
}
