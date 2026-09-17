import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @Bindable var model: ViewerModel
    @Bindable var oscController: OSCController
    @Bindable var midiController: MIDIController
    @State private var screenAwakeController = ScreenAwakeController()
    @State private var isImporting = false
    @State private var isShowingLibrary = false
    @State private var isShowingSettings = false
    @State private var isHUDVisible = false
    @State private var hudActivity = 0
    @State private var pageEntry = ""
    @FocusState private var isPageEntryFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let document = model.document {
                PDFPageView(document: document, pageIndex: model.currentPageIndex)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(pageTurnGesture)
                    .onTapGesture {
                        toggleHUD()
                    }
            } else {
                EmptyViewerView(
                    hasDocuments: !model.documents.isEmpty,
                    libraryAction: { isShowingLibrary = true },
                    importAction: { isImporting = true }
                )
            }

            if isHUDVisible, model.hasDocument {
                ViewerHUD(
                    documentName: model.documentName,
                    currentPage: model.displayedPageNumber,
                    pageCount: model.pageCount,
                    isMIDIConnected: !midiController.sources.isEmpty,
                    isOSCRunning: oscController.status.isRunning,
                    pageEntry: $pageEntry,
                    isPageEntryFocused: $isPageEntryFocused,
                    firstAction: { performFromHUD(.firstPage) },
                    previousAction: { performFromHUD(.previousPage) },
                    nextAction: { performFromHUD(.nextPage) },
                    lastAction: { performFromHUD(.lastPage) },
                    jumpAction: jumpToEnteredPage,
                    documentAction: {
                        isShowingLibrary = true
                        hideHUD()
                    },
                    settingsAction: showSettings,
                    dismissAction: hideHUD,
                    interactionAction: keepHUDVisible
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHUDVisible)
        .sheet(isPresented: $isShowingLibrary) {
            DocumentLibraryView(model: model, isImporting: $isImporting)
        }
        .sheet(isPresented: $isShowingSettings) {
            GeneralSettingsView(model: model, oscController: oscController, midiController: midiController)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            model.importDocument(from: url)
            pageEntry = ""
            hideHUD()
        }
        .alert(
            "Viewtiful",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.clearPresentedError() } }
            )
        ) {
            Button("OK") {
                model.clearPresentedError()
            }
        } message: {
            Text(model.presentedError ?? "")
        }
        .focusable()
        .focused($isPageEntryFocused, equals: false)
        .onKeyPress(phases: .down) { keyPress in
            handleKeyPress(keyPress)
        }
        .onChange(of: scenePhase, initial: true) {
            updateScreenAwakeState()
            updateOSCState()
        }
        .task {
            oscController.onAction = { action in
                model.perform(action)
            }
            midiController.onAction = { action in
                model.perform(action)
            }
            updateOSCState()
        }
        .onChange(of: model.keepScreenAwake, initial: true) {
            updateScreenAwakeState()
        }
        .onChange(of: model.hasDocument, initial: true) {
            updateScreenAwakeState()
        }
        .onChange(of: isPageEntryFocused) {
            if !isPageEntryFocused, isHUDVisible {
                keepHUDVisible()
            }
        }
        .task(id: hudActivity) {
            guard isHUDVisible, !isPageEntryFocused else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !isPageEntryFocused else { return }
            isHUDVisible = false
        }
    }

    private func updateOSCState() {
        if scenePhase == .active {
            oscController.applyConfiguration()
        } else {
            oscController.stop()
        }
    }

    private func showSettings() {
        hideHUD()
        #if os(macOS)
        openSettings()
        #else
        isShowingSettings = true
        #endif
    }

    private func updateScreenAwakeState() {
        let shouldStayAwake = scenePhase == .active && model.hasDocument && model.keepScreenAwake
        screenAwakeController.update(shouldStayAwake: shouldStayAwake)
    }

    private var pageTurnGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                perform(value.translation.width < 0 ? .nextPage : .previousPage)
            }
    }

    private func perform(_ action: ViewtifulAction) {
        model.perform(action)
        pageEntry = ""
    }

    private func performFromHUD(_ action: ViewtifulAction) {
        perform(action)
        keepHUDVisible()
    }

    private func jumpToEnteredPage() {
        guard let pageNumber = Int(pageEntry) else { return }
        model.perform(.goToPage(pageNumber))
        isPageEntryFocused = false
        pageEntry = ""
        keepHUDVisible()
    }

    private func toggleHUD() {
        if isHUDVisible {
            hideHUD()
        } else {
            keepHUDVisible()
        }
    }

    private func keepHUDVisible() {
        isHUDVisible = true
        hudActivity += 1
    }

    private func hideHUD() {
        isPageEntryFocused = false
        isHUDVisible = false
        pageEntry = ""
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard !isPageEntryFocused else { return .ignored }

        switch keyPress.key {
        case .rightArrow:
            perform(.nextPage)
        case .leftArrow:
            perform(.previousPage)
        case .space:
            perform(keyPress.modifiers.contains(.shift) ? .previousPage : .nextPage)
        case .home:
            perform(.firstPage)
        case .end:
            perform(.lastPage)
        case .escape:
            hideHUD()
        default:
            return .ignored
        }

        return .handled
    }
}

private struct EmptyViewerView: View {
    let hasDocuments: Bool
    let libraryAction: () -> Void
    let importAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Show Document", systemImage: "doc.richtext")
        } description: {
            Text(hasDocuments ? "Choose a document from the library." : "Import a PDF to begin.")
        } actions: {
            HStack {
                if hasDocuments {
                    Button("Documents", systemImage: "folder") {
                        libraryAction()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Import PDF", systemImage: "plus") {
                        importAction()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Import PDF", systemImage: "plus") {
                        importAction()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

private struct ViewerHUD: View {
    let documentName: String
    let currentPage: Int
    let pageCount: Int
    let isMIDIConnected: Bool
    let isOSCRunning: Bool
    @Binding var pageEntry: String
    let isPageEntryFocused: FocusState<Bool>.Binding
    let firstAction: () -> Void
    let previousAction: () -> Void
    let nextAction: () -> Void
    let lastAction: () -> Void
    let jumpAction: () -> Void
    let documentAction: () -> Void
    let settingsAction: () -> Void
    let dismissAction: () -> Void
    let interactionAction: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 12) {
                statusBar

                Spacer(minLength: 0)

                controlBar
            }
            .padding()
        }
        .accessibilityElement(children: .contain)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(documentName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 12)

            statusIndicator(
                label: isMIDIConnected ? "MIDI Connected" : "MIDI Disconnected",
                systemImage: "pianokeys",
                isActive: isMIDIConnected
            )

            statusIndicator(
                label: isOSCRunning ? "OSC Listener Running" : "OSC Listener Stopped",
                systemImage: "network",
                isActive: isOSCRunning
            )

            Text("\(currentPage) / \(pageCount)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Page \(currentPage) of \(pageCount)")

            Button("Hide Controls", systemImage: "xmark") {
                dismissAction()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .glassEffect()
        .frame(maxWidth: 560)
    }

    private func statusIndicator(
        label: LocalizedStringKey,
        systemImage: String,
        isActive: Bool
    ) -> some View {
        Image(systemName: systemImage)
            .foregroundStyle(isActive ? Color.green : Color.secondary)
            .accessibilityLabel(label)
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            hudButton("Documents", systemImage: "folder", action: documentAction)
            Divider().frame(height: 24)
            hudButton("First Page", systemImage: "backward.end.fill", action: firstAction)
            hudButton("Previous Page", systemImage: "chevron.left", action: previousAction)

            TextField("\(currentPage)", text: $pageEntry)
                .focused(isPageEntryFocused)
                .textFieldStyle(.plain)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 54, height: 34)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .onTapGesture {
                    interactionAction()
                }
                .onSubmit(jumpAction)
                .accessibilityLabel("Go to page")
                .accessibilityHint("Enter a page from 1 through \(pageCount)")

            hudButton("Next Page", systemImage: "chevron.right", action: nextAction)
            hudButton("Last Page", systemImage: "forward.end.fill", action: lastAction)
            Divider().frame(height: 24)
            hudButton("Settings", systemImage: "gearshape", action: settingsAction)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 52)
        .glassEffect()
    }

    private func hudButton(
        _ label: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview {
    ContentView(model: ViewerModel(), oscController: OSCController(), midiController: MIDIController())
}
