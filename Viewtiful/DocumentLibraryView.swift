import SwiftUI
import UniformTypeIdentifiers

struct DocumentLibraryView: View {
    @Bindable var model: ViewerModel
    @State private var isImporting = false
    @State private var searchText = ""
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
                        if model.libraryNeedsRecovery {
                            Button("Start New Library", systemImage: "arrow.counterclockwise", role: .destructive) {
                                model.startNewLibrary()
                            }
                        } else {
                            Button("Import PDF", systemImage: "plus") {
                                isImporting = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    List(filteredDocuments) { document in
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
                    .overlay {
                        if filteredDocuments.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                    .searchable(text: $searchText, prompt: "Find a document")
                }
            }
            .navigationTitle("Documents")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }

                ToolbarItem(placement: importPlacement) {
                    if !model.libraryNeedsRecovery {
                        Button("Import PDF", systemImage: "plus") {
                            isImporting = true
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                model.importDocument(from: url)
                if model.presentedError == nil { dismiss() }
            case .failure(let error): model.reportImportError(error)
            }
        }
        .alert("Unable to Complete Action", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.clearPresentedError() } }
        )) {
            if model.libraryNeedsRecovery && model.libraryRecoveryURL != nil {
                Button("Start New Library", role: .destructive) { model.startNewLibrary() }
            }
            Button("OK") { model.clearPresentedError() }
        } message: {
            Text(model.presentedError ?? "")
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

    private var importPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .cancellationAction
        #else
        .primaryAction
        #endif
    }

    private var filteredDocuments: [ShowDocument] {
        guard !searchText.isEmpty else { return model.documents }
        return model.documents.filter { $0.displayName.localizedStandardContains(searchText) }
    }

}

private struct DocumentRow: View {
    let document: ShowDocument
    let isActive: Bool
    let openAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        HStack {
            Button(action: openAction) {
                rowLabel
            }
            .buttonStyle(.plain)
            .accessibilityHint(isActive ? "Currently open" : "Opens this document")

            Menu {
                Button("Open", systemImage: "doc", action: openAction)
                Button("Remove from Viewtiful", systemImage: "trash", role: .destructive, action: removeAction)
            } label: {
                Label("Document Actions", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for \(document.displayName)")
        }
        .swipeActions(allowsFullSwipe: false) {
            Button("Remove", systemImage: "trash", role: .destructive, action: removeAction)
        }
        .contextMenu {
            Button("Open", systemImage: "doc", action: openAction)
            Button("Remove", systemImage: "trash", role: .destructive, action: removeAction)
        }
    }

    private var rowLabel: some View {
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
}
