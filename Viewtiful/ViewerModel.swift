import Foundation
import Observation
import PDFKit

enum ViewtifulAction: Sendable {
    case nextPage
    case previousPage
    /// A page counted from the front of the PDF, where the first page is 1.
    case goToPage(Int)
    /// A page as the script numbers it, which the document's page offset shifts
    /// away from the PDF's own ordering.
    case goToLabeledPage(Int)
    case firstPage
    case lastPage
}

enum StartupBehavior: String, CaseIterable, Identifiable, Sendable {
    case firstPage
    case resumeLastPage

    var id: Self { self }
}

/// How page colors are chosen: follow the system's light or dark appearance, or stay pinned.
enum PDFColorAppearance: String, CaseIterable, Identifiable, Sendable {
    case matchSystem
    case normal
    case inverted

    var id: Self { self }
}

/// How much of the viewport is left clear around the page. The border is the page's
/// own paper carried past its edge, so it follows the page's colors rather than the
/// window's: white normally, black once pages are inverted.
enum PageMargin: String, CaseIterable, Identifiable, Sendable {
    case none
    case small
    case medium
    case large

    var id: Self { self }

    var displayName: String {
        switch self {
        case .none: "None"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// A fraction of the viewport's shorter side, so the border stays proportionate
    /// on a phone, an iPad, and a full-screen Mac alike.
    var fraction: Double {
        switch self {
        case .none: 0
        case .small: 0.02
        case .medium: 0.045
        case .large: 0.08
        }
    }
}

enum ViewerPresentationRequest: Equatable {
    case openDocument
}

/// A document opened earlier, remembered as a bookmark rather than as a copy. Viewtiful
/// reads shows in place from wherever the system browser found them, so the only thing
/// worth keeping is how to get back to the file and which page it was left on.
struct RecentDocument: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    var bookmark: Data
    var pageCount: Int
    var lastPageIndex: Int
    var lastOpened: Date
    /// How far the script's own page numbering runs ahead of the PDF's: the number
    /// on the first page of the PDF, less one. This belongs to the file rather than
    /// to how it is being read, so it is remembered per document like the page.
    var pageOffset: Int

    init(id: String, displayName: String, bookmark: Data, pageCount: Int,
         lastPageIndex: Int, lastOpened: Date, pageOffset: Int = 0) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.pageCount = pageCount
        self.lastPageIndex = lastPageIndex
        self.lastOpened = lastOpened
        self.pageOffset = pageOffset
    }

    /// Decoded by hand so recents written before page offsets existed still load;
    /// a list that fails to decode is discarded wholesale by the model.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        lastPageIndex = try container.decode(Int.self, forKey: .lastPageIndex)
        lastOpened = try container.decode(Date.self, forKey: .lastOpened)
        pageOffset = try container.decodeIfPresent(Int.self, forKey: .pageOffset) ?? 0
    }
}

@MainActor
@Observable
final class ViewerModel {
    private static let recentDocumentLimit = 20

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pendingPersistenceTask: Task<Void, Never>?
    /// Access to the open document's file, held for as long as it is on screen. PDFKit
    /// reads pages lazily, so relinquishing the sandbox extension at open time would
    /// leave later pages unreadable mid-show.
    @ObservationIgnored private var accessedURL: URL?

    private(set) var document: PDFDocument?
    private(set) var activeDocumentID: RecentDocument.ID?
    private(set) var currentPageIndex = 0
    private(set) var recentDocuments: [RecentDocument] = []
    private(set) var presentedError: String?
    /// Retains a menu request until a viewer window is available to present its picker.
    private(set) var presentationRequest: ViewerPresentationRequest?

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

    var pdfColorAppearance: PDFColorAppearance {
        didSet { defaults.set(pdfColorAppearance.rawValue, forKey: Keys.pdfColorAppearance) }
    }

    /// Mirrors the environment's color scheme so `.matchSystem` resolves outside of a view.
    var systemIsDark = false

    /// Pages invert either because the system is in dark mode or because it was asked for
    /// explicitly. Setting this pins the choice, leaving `.matchSystem` behind.
    var invertPDFColors: Bool {
        get {
            switch pdfColorAppearance {
            case .matchSystem: systemIsDark
            case .normal: false
            case .inverted: true
            }
        }
        set { pdfColorAppearance = newValue ? .inverted : .normal }
    }

    var invertAnnotations: Bool {
        didSet { defaults.set(invertAnnotations, forKey: "invertAnnotations") }
    }

    var edgeTapNavigationEnabled: Bool {
        didSet { defaults.set(edgeTapNavigationEnabled, forKey: Keys.edgeTapNavigationEnabled) }
    }

    var pageMargin: PageMargin {
        didSet { defaults.set(pageMargin.rawValue, forKey: Keys.pageMargin) }
    }

    var pageCount: Int {
        document?.pageCount ?? 0
    }

    /// The offset for the document on screen. Reading it with nothing open, or
    /// writing it to an unchanged value, leaves the stored recents alone.
    var pageOffset: Int {
        get { activeDocument?.pageOffset ?? 0 }
        set {
            guard let activeDocumentID,
                  let index = recentDocuments.firstIndex(where: { $0.id == activeDocumentID }),
                  recentDocuments[index].pageOffset != newValue else { return }
            recentDocuments[index].pageOffset = newValue
            saveRecentDocuments()
        }
    }

    /// The range the script numbers its pages over, which is what the page readout
    /// shows and what the page field accepts.
    var labeledPageRange: ClosedRange<Int>? {
        guard pageCount > 0 else { return nil }
        return (1 + pageOffset)...(pageCount + pageOffset)
    }

    var displayedPageNumber: Int {
        pageCount == 0 ? 0 : currentPageIndex + 1 + pageOffset
    }

    var firstPageNumber: Int {
        1 + pageOffset
    }

    var lastPageNumber: Int {
        pageCount == 0 ? 0 : pageCount + pageOffset
    }

    var hasDocument: Bool {
        document != nil
    }

    var documentName: String {
        activeDocument?.displayName ?? ""
    }

    var activeDocument: RecentDocument? {
        guard let activeDocumentID else { return nil }
        return recentDocuments.first { $0.id == activeDocumentID }
    }

    /// Recents are kept newest first, so the most recent show is the one to reopen.
    var lastDocument: RecentDocument? {
        recentDocuments.first
    }

    var canOpenLastDocument: Bool {
        lastDocument != nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedBehavior = defaults.string(forKey: Keys.startupBehavior)
        startupBehavior = StartupBehavior(rawValue: savedBehavior ?? "") ?? .resumeLastPage

        if defaults.object(forKey: Keys.keepScreenAwake) == nil {
            keepScreenAwake = true
        } else {
            keepScreenAwake = defaults.bool(forKey: Keys.keepScreenAwake)
        }

        if let savedAppearance = defaults.string(forKey: Keys.pdfColorAppearance) {
            pdfColorAppearance = PDFColorAppearance(rawValue: savedAppearance) ?? .matchSystem
        } else if defaults.bool(forKey: Keys.legacyInvertPDFColors) {
            // Carry forward the older on/off preference: an explicit invert stays explicit.
            pdfColorAppearance = .inverted
        } else {
            pdfColorAppearance = .matchSystem
        }
        invertAnnotations = defaults.bool(forKey: "invertAnnotations")
        if defaults.object(forKey: Keys.edgeTapNavigationEnabled) == nil {
            edgeTapNavigationEnabled = true
        } else {
            edgeTapNavigationEnabled = defaults.bool(forKey: Keys.edgeTapNavigationEnabled)
        }
        pageMargin = PageMargin(rawValue: defaults.string(forKey: Keys.pageMargin) ?? "") ?? .none

        loadRecentDocuments()
    }

    deinit {
        pendingPersistenceTask?.cancel()
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    func requestPresentation(_ request: ViewerPresentationRequest) {
        presentationRequest = request
    }

    func takePresentationRequest() -> ViewerPresentationRequest? {
        defer { presentationRequest = nil }
        return presentationRequest
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
        case .goToLabeledPage(let pageNumber):
            let index = pageNumber - 1 - pageOffset
            guard (0..<pageCount).contains(index) else { return }
            currentPageIndex = index
        case .firstPage:
            currentPageIndex = 0
        case .lastPage:
            currentPageIndex = pageCount - 1
        }

        guard currentPageIndex != previousPageIndex else { return }
        persistCurrentPage()
    }

    /// Opens a PDF the person chose in the system browser or file picker, reading it
    /// where it sits. The bookmark recorded here is what makes "Open Last" work after
    /// a relaunch, and it is refreshed on every open so a moved file heals itself.
    func openDocument(at url: URL) {
        presentedError = nil
        cancelPendingPersistence()

        // URLs handed over by the browser sit outside the sandbox until access is granted.
        // A `false` result is not fatal: URLs that were never security scoped, such as
        // files already inside the container, still read normally.
        let didStartAccessing = url.startAccessingSecurityScopedResource()

        guard let loadedDocument = PDFDocument(url: url), !loadedDocument.isLocked, loadedDocument.pageCount > 0 else {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            presentedError = "“\(url.lastPathComponent)” could not be opened. It may not be a readable PDF."
            return
        }

        let id = Self.identifier(for: url)
        var record = recentDocuments.first { $0.id == id } ?? RecentDocument(
            id: id,
            displayName: url.deletingPathExtension().lastPathComponent,
            bookmark: Data(),
            pageCount: loadedDocument.pageCount,
            lastPageIndex: 0,
            lastOpened: .now
        )
        record.displayName = url.deletingPathExtension().lastPathComponent
        record.pageCount = loadedDocument.pageCount
        if let refreshedBookmark = try? Self.bookmark(for: url) {
            record.bookmark = refreshedBookmark
        }

        show(loadedDocument, as: record, accessing: didStartAccessing ? url : nil)
    }

    func openRecentDocument(_ recent: RecentDocument) {
        presentedError = nil
        cancelPendingPersistence()

        guard !recent.bookmark.isEmpty else {
            forgetRecentDocument(recent)
            presentedError = "Viewtiful no longer has permission to reopen “\(recent.displayName)”. Open it again from the browser."
            return
        }

        guard let url = Self.resolve(recent.bookmark) else {
            forgetRecentDocument(recent)
            presentedError = "“\(recent.displayName)” could not be found. It may have been moved, renamed, or deleted."
            return
        }

        openDocument(at: url)
    }

    func openLastDocument() {
        guard let lastDocument else { return }
        openRecentDocument(lastDocument)
    }


    func closeDocument() {
        flushPendingPersistence()
        relinquishAccess()
        document = nil
        activeDocumentID = nil
        currentPageIndex = 0
    }

    func clearRecentDocuments() {
        recentDocuments.removeAll { $0.id != activeDocumentID }
        saveRecentDocuments()
    }

    /// Forgets a single remembered document. The open one stays: its page position
    /// and offset are written back to its entry for as long as it is on screen.
    func removeRecentDocument(_ recent: RecentDocument) {
        guard recent.id != activeDocumentID else { return }
        forgetRecentDocument(recent)
    }

    func canRemoveRecentDocument(_ recent: RecentDocument) -> Bool {
        recent.id != activeDocumentID
    }

    func reportOpenError(_ error: Error) {
        guard (error as NSError).code != NSUserCancelledError else { return }
        presentedError = "The PDF could not be opened. \(error.localizedDescription)"
    }

    func clearPresentedError() {
        presentedError = nil
    }

    /// Writes the latest page position immediately. Call this at lifecycle
    /// boundaries where queued persistence must be complete before suspension.
    func flushPendingPersistence() {
        cancelPendingPersistence()
        saveRecentDocuments()
    }

    private func show(_ loadedDocument: PDFDocument, as record: RecentDocument, accessing url: URL?) {
        relinquishAccess()
        accessedURL = url
        document = loadedDocument
        activeDocumentID = record.id

        let restoredPage = startupBehavior == .resumeLastPage ? record.lastPageIndex : 0
        currentPageIndex = min(max(restoredPage, 0), loadedDocument.pageCount - 1)

        var updated = record
        updated.lastOpened = .now
        updated.lastPageIndex = currentPageIndex
        recentDocuments.removeAll { $0.id == updated.id }
        recentDocuments.insert(updated, at: 0)
        if recentDocuments.count > Self.recentDocumentLimit {
            recentDocuments.removeLast(recentDocuments.count - Self.recentDocumentLimit)
        }
        saveRecentDocuments()
    }

    private func forgetRecentDocument(_ recent: RecentDocument) {
        recentDocuments.removeAll { $0.id == recent.id }
        saveRecentDocuments()
    }

    private func relinquishAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    private func persistCurrentPage() {
        guard let activeDocumentID,
              let index = recentDocuments.firstIndex(where: { $0.id == activeDocumentID }) else { return }
        recentDocuments[index].lastPageIndex = currentPageIndex
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.saveRecentDocuments()
            self.pendingPersistenceTask = nil
        }
    }

    private func cancelPendingPersistence() {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
    }

    private func loadRecentDocuments() {
        guard let data = defaults.data(forKey: Keys.recentDocuments) else { return }
        guard let decoded = try? JSONDecoder().decode([RecentDocument].self, from: data) else {
            // Recents are a convenience over files Viewtiful does not own, so a list that
            // cannot be read is simply forgotten rather than reported.
            defaults.removeObject(forKey: Keys.recentDocuments)
            return
        }
        recentDocuments = decoded.sorted { $0.lastOpened > $1.lastOpened }
    }

    private func saveRecentDocuments() {
        guard let data = try? JSONEncoder().encode(recentDocuments) else { return }
        defaults.set(data, forKey: Keys.recentDocuments)
    }

    /// A show is identified by where it lives, which keeps the page position attached to
    /// the file across launches without Viewtiful having to own or index it.
    private static func identifier(for url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    private static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        // The Mac sandbox only restores access through an explicitly scoped bookmark, and
        // Viewtiful never writes to a show.
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        // A stale bookmark still resolves; opening the document rewrites it.
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private enum Keys {
        static let recentDocuments = "recentDocuments"
        static let startupBehavior = "startupBehavior"
        static let keepScreenAwake = "keepScreenAwake"
        static let edgeTapNavigationEnabled = "edgeTapNavigationEnabled"
        static let pageMargin = "pageMargin"
        static let pdfColorAppearance = "pdfColorAppearance"
        static let legacyInvertPDFColors = "invertPDFColors"
    }
}
