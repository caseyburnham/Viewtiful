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
    private(set) var document: PDFDocument?
    private(set) var activeDocumentID: ShowDocument.ID?
    private(set) var currentPageIndex = 0
    private(set) var documents: [ShowDocument] = []
    private(set) var presentedError: String?

    var startupBehavior: StartupBehavior {
        didSet {
            UserDefaults.standard.set(startupBehavior.rawValue, forKey: Keys.startupBehavior)
        }
    }

    var keepScreenAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenAwake, forKey: Keys.keepScreenAwake)
        }
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

    init() {
        let savedBehavior = UserDefaults.standard.string(forKey: Keys.startupBehavior)
        startupBehavior = StartupBehavior(rawValue: savedBehavior ?? "") ?? .resumeLastPage

        if UserDefaults.standard.object(forKey: Keys.keepScreenAwake) == nil {
            keepScreenAwake = true
        } else {
            keepScreenAwake = UserDefaults.standard.bool(forKey: Keys.keepScreenAwake)
        }

        loadLibrary()
        restoreLastDocument()
    }

    func perform(_ action: ViewtifulAction) {
        guard pageCount > 0 else { return }

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

        persistCurrentPage()
    }

    func importDocument(from sourceURL: URL) {
        presentedError = nil
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

            guard let loadedDocument = PDFDocument(url: destinationURL), loadedDocument.pageCount > 0 else {
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
            sortLibrary()
            saveLibrary()
            open(record, loadedDocument: loadedDocument)
        } catch {
            presentedError = "The selected PDF could not be imported."
        }
    }

    func selectDocument(_ document: ShowDocument) {
        do {
            try openDocument(document)
        } catch {
            presentedError = "The selected PDF can no longer be opened."
        }
    }

    func removeDocument(_ documentToRemove: ShowDocument) {
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
                UserDefaults.standard.removeObject(forKey: Keys.lastDocumentID)
            }
        } catch {
            presentedError = "The document could not be removed."
        }
    }

    func clearPresentedError() {
        presentedError = nil
    }

    private func openDocument(_ record: ShowDocument) throws {
        let documentURL = try url(for: record)
        guard
            FileManager.default.fileExists(atPath: documentURL.path),
            let loadedDocument = PDFDocument(url: documentURL),
            loadedDocument.pageCount > 0
        else {
            throw ViewerError.invalidPDF
        }

        open(record, loadedDocument: loadedDocument)
    }

    private func open(_ record: ShowDocument, loadedDocument: PDFDocument) {
        document = loadedDocument
        activeDocumentID = record.id

        let restoredPage = startupBehavior == .resumeLastPage ? record.lastPageIndex : 0
        currentPageIndex = min(max(restoredPage, 0), loadedDocument.pageCount - 1)

        updateRecord(record.id) {
            $0.lastOpened = .now
            $0.lastPageIndex = currentPageIndex
        }
        UserDefaults.standard.set(record.id.uuidString, forKey: Keys.lastDocumentID)
        sortLibrary()
        saveLibrary()
    }

    private func restoreLastDocument() {
        guard
            let idString = UserDefaults.standard.string(forKey: Keys.lastDocumentID),
            let id = UUID(uuidString: idString),
            let record = documents.first(where: { $0.id == id })
        else {
            return
        }

        do {
            try openDocument(record)
        } catch {
            UserDefaults.standard.removeObject(forKey: Keys.lastDocumentID)
        }
    }

    private func persistCurrentPage() {
        guard let activeDocumentID else { return }
        updateRecord(activeDocumentID) {
            $0.lastPageIndex = currentPageIndex
        }
        saveLibrary()
    }

    private func updateRecord(_ id: ShowDocument.ID, update: (inout ShowDocument) -> Void) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        update(&documents[index])
    }

    private func loadLibrary() {
        do {
            let data = try Data(contentsOf: libraryURL())
            documents = try JSONDecoder().decode([ShowDocument].self, from: data)
            documents.removeAll { record in
                guard let recordURL = try? url(for: record) else { return true }
                return !FileManager.default.fileExists(atPath: recordURL.path)
            }
            sortLibrary()
            saveLibrary()
        } catch {
            documents = []
        }
    }

    private func saveLibrary() {
        do {
            let data = try JSONEncoder().encode(documents)
            try data.write(to: libraryURL(), options: .atomic)
        } catch {
            presentedError = "Viewtiful could not save the document library."
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
    }

    private enum ViewerError: Error {
        case invalidPDF
    }
}
