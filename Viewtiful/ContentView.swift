import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    #endif
    @Bindable var model: ViewerModel
    @Bindable var oscController: OSCController
    @Bindable var midiController: MIDIController
    @State private var screenAwakeController = ScreenAwakeController()
    @State private var isImporting = false
    @State private var isShowingLibrary = false
    @State private var isShowingSettings = false
    @State private var isShowingMonitor = false
    @State private var isShowingPageEntry = false
    @State private var controlsVisible = true
    @State private var zoomLevel: PDFZoomLevel = .fit
    @State private var pinchStartZoom: Double?
    @State private var pageEntry = ""
    @FocusState private var pageEntryFocused: Bool

    var body: some View {
        NavigationStack {
            viewer
                .navigationTitle(model.hasDocument ? model.documentName : "Viewtiful")
                .toolbar { viewerToolbar }
                #if os(macOS)
                .toolbarVisibility(controlsVisible ? .visible : .hidden, for: .windowToolbar)
                #else
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(controlsVisible ? .visible : .hidden, for: .navigationBar)
                #endif
        }
        .sheet(isPresented: $isShowingLibrary) {
            DocumentLibraryView(model: model)
                #if os(macOS)
                .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 480)
                #endif
        }
        .sheet(isPresented: $isShowingSettings) {
            GeneralSettingsView(model: model, oscController: oscController, midiController: midiController)
        }
        .sheet(isPresented: $isShowingMonitor) {
            MonitorView(midiController: midiController, oscController: oscController)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): model.importDocument(from: url)
            case .failure(let error): model.reportImportError(error)
            }
        }
        .alert("Unable to Complete Action", isPresented: Binding(
            get: { model.presentedError != nil && !isShowingLibrary },
            set: { if !$0 { model.clearPresentedError() } }
        )) {
            if model.libraryNeedsRecovery && model.libraryRecoveryURL != nil {
                Button("Start New Library", role: .destructive) { model.startNewLibrary() }
            }
            Button("OK") { model.clearPresentedError() }
        } message: {
            Text(model.presentedError ?? "")
        }
        .focusedSceneValue(\.viewerCommands, ViewerCommandActions(
            hasDocument: model.hasDocument,
            importDocument: { isImporting = true },
            showLibrary: { isShowingLibrary = true },
            goToPage: showPageEntry,
            controlsVisible: controlsVisible,
            toggleControls: toggleControls,
            fitPage: { zoomLevel = .fit },
            perform: model.perform
        ))
        .onChange(of: scenePhase, initial: true) { updateLifecycle() }
        .onChange(of: model.keepScreenAwake) { updateLifecycle() }
        .onChange(of: model.hasDocument) {
            if !model.hasDocument { controlsVisible = true }
            updateLifecycle()
        }
        .onChange(of: model.activeDocumentID) { zoomLevel = .fit }
        .onDisappear { model.flushPendingPersistence() }
        .task {
            oscController.onAction = model.perform
            midiController.onAction = model.perform
            updateLifecycle()
        }
    }

    private var viewerBackground: Color {
        #if os(macOS)
        Color(nsColor: model.invertPDFColors ? .black : .windowBackgroundColor)
        #else
        Color(uiColor: model.invertPDFColors ? .black : .systemBackground)
        #endif
    }

    private var viewer: some View {
        GeometryReader { proxy in
            ZStack {
                if let document = model.document {
                    viewerBackground
                    PDFPageView(document: document, pageIndex: model.currentPageIndex,
                                invertColors: model.invertPDFColors, invertAnnotations: model.invertAnnotations,
                                zoom: zoomLevel,
                                onPageTurn: turnPage,
                                onGoToPage: showPageEntry,
                                onFitPage: { zoomLevel = .fit })
                        .accessibilityLabel("\(model.documentName), page \(model.displayedPageNumber) of \(model.pageCount)")
                        .simultaneousGesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    handleDocumentTap(at: value.location, in: proxy.size)
                                }
                        )
                } else {
                    ContentUnavailableView {
                        Label("Open a Show Document", systemImage: "doc.richtext")
                    } description: {
                        Text("Display a PDF and turn pages with a keyboard, MIDI, or OSC.")
                    } actions: {
                        Button("Import PDF…", systemImage: "plus") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                        if !model.documents.isEmpty {
                            Button("Choose Document…", systemImage: "folder") { isShowingLibrary = true }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 40).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            turnPage(value.translation.width < 0 ? .nextPage : .previousPage)
        })
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    updateZoom(for: value.magnification)
                }
                .onEnded { value in
                    updateZoom(for: value.magnification)
                    pinchStartZoom = nil
                }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { key in
            guard !isShowingLibrary, !isShowingSettings, !isShowingMonitor, !isImporting, !isShowingPageEntry,
                  key.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
            switch key.key {
            case .rightArrow: model.perform(.nextPage)
            case .leftArrow: model.perform(.previousPage)
            case .space: model.perform(key.modifiers.contains(.shift) ? .previousPage : .nextPage)
            case .home: model.perform(.firstPage)
            case .end: model.perform(.lastPage)
            case .escape: return .ignored
            default: return .ignored
            }
            return .handled
        }
        .accessibilityAction(named: "Next Page") { model.perform(.nextPage) }
        .accessibilityAction(named: "Previous Page") { model.perform(.previousPage) }
        .overlay(alignment: .bottom) {
            if model.hasDocument, controlsVisible {
                pageNavigationControls
                    .padding()
                    .transition(.opacity)
            }
        }
    }

    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Documents", systemImage: "folder") { isShowingLibrary = true }
                .help("Choose a show document")
            Button("Import PDF", systemImage: "plus") { isImporting = true }
                .help("Import a PDF")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Zoom") {
                    Button("Zoom In", systemImage: "plus.magnifyingglass") { adjustZoom(by: 1.25) }
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") { adjustZoom(by: 1 / 1.25) }
                    Button("Fit Page", systemImage: "arrow.up.left.and.arrow.down.right") { zoomLevel = .fit }
                }
                Section("PDF Appearance") {
                    Toggle("Invert Colors", systemImage: "circle.lefthalf.filled", isOn: $model.invertPDFColors)
                }
                Button("Hide Controls", systemImage: "eye.slash", action: hideControls)
            } label: {
                Label("Viewer Options", systemImage: "slider.horizontal.3")
            }
            .disabled(!model.hasDocument)
            .help("Zoom, PDF appearance, and viewer controls")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Monitors", systemImage: "waveform.path.ecg") {
                #if os(macOS)
                openWindow(id: "monitors")
                #else
                isShowingMonitor = true
                #endif
            }
            .help("Open MIDI and OSC monitors")
            Button("Settings", systemImage: "gearshape") {
                #if os(macOS)
                openSettings()
                #else
                isShowingSettings = true
                #endif
            }
            .help("Open Settings")
        }
    }

    private var pageNavigationControls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button("Previous Page", systemImage: "chevron.left") { turnPage(.previousPage) }
                    .labelStyle(.iconOnly)
                    .help("Previous page (Left Arrow)")

                Button(action: showPageEntry) {
                    Text("\(model.displayedPageNumber) of \(model.pageCount)")
                        .monospacedDigit()
                        .frame(minWidth: 80)
                }
                .accessibilityLabel("Go to Page")
                .accessibilityValue("\(model.displayedPageNumber) of \(model.pageCount)")
                .help("Go to a page (⌘L)")
                .popover(isPresented: $isShowingPageEntry) {
                    Form {
                        TextField("Page", text: $pageEntry)
                            .focused($pageEntryFocused)
                            #if !os(macOS)
                            .keyboardType(.numberPad)
                            #endif
                            .onSubmit(jumpToPage)
                        Text("Enter a page from 1 to \(model.pageCount).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Go to Page", action: jumpToPage)
                            .disabled(!isValidPage)
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding()
                    .frame(idealWidth: 280)
                    .presentationCompactAdaptation(.popover)
                    .onAppear { pageEntryFocused = true }
                }

                Button("Next Page", systemImage: "chevron.right") { turnPage(.nextPage) }
                    .labelStyle(.iconOnly)
                    .help("Next page (Right Arrow or Space)")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    private func turnPage(_ action: ViewtifulAction) {
        model.perform(action)
    }

    private func handleDocumentTap(at location: CGPoint, in size: CGSize) {
        guard model.hasDocument else { return }

        if model.edgeTapNavigationEnabled {
            let edgeWidth = min(max(size.width * 0.15, 56), 160)
            if location.x <= edgeWidth {
                turnPage(.previousPage)
                hideControls()
                return
            }
            if location.x >= size.width - edgeWidth {
                turnPage(.nextPage)
                hideControls()
                return
            }
        }

        toggleControls()
    }

    private func hideControls() {
        guard controlsVisible else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            controlsVisible = false
        }
        isShowingPageEntry = false
        pageEntryFocused = false
        pageEntry = ""
    }

    private func adjustZoom(by multiplier: Double) {
        let current: Double
        switch zoomLevel {
        case .fit: current = 1
        case .factor(let factor): current = factor
        }
        zoomLevel = .factor(min(max(current * multiplier, 0.25), 4))
    }

    private func toggleControls() {
        guard model.hasDocument else { return }
        if controlsVisible {
            hideControls()
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                controlsVisible = true
            }
        }
    }

    private func updateZoom(for magnification: CGFloat) {
        if pinchStartZoom == nil {
            switch zoomLevel {
            case .fit: pinchStartZoom = 1
            case .factor(let factor): pinchStartZoom = factor
            }
        }
        if let pinchStartZoom {
            zoomLevel = .factor(min(max(pinchStartZoom * magnification, 0.25), 4))
        }
    }

    private var isValidPage: Bool {
        guard let page = Int(pageEntry), model.pageCount > 0 else { return false }
        return (1...model.pageCount).contains(page)
    }

    private func showPageEntry() {
        guard model.hasDocument else { return }
        controlsVisible = true
        pageEntry = String(model.displayedPageNumber)
        isShowingPageEntry = true
    }

    private func jumpToPage() {
        guard let page = Int(pageEntry), model.pageCount > 0,
              (1...model.pageCount).contains(page) else { return }
        model.perform(.goToPage(page))
        isShowingPageEntry = false
    }

    private func updateLifecycle() {
        #if os(macOS)
        // A Mac show viewer must keep receiving commands while another app has focus.
        let isAvailable = true
        #else
        let isAvailable = scenePhase != .background
        #endif
        oscController.setAvailable(isAvailable)
        screenAwakeController.update(shouldStayAwake: isAvailable && model.hasDocument && model.keepScreenAwake)
    }
}

struct ViewerCommandActions {
    let hasDocument: Bool
    let importDocument: () -> Void
    let showLibrary: () -> Void
    let goToPage: () -> Void
    let controlsVisible: Bool
    let toggleControls: () -> Void
    let fitPage: () -> Void
    let perform: (ViewtifulAction) -> Void
}

private struct ViewerCommandsKey: FocusedValueKey {
    typealias Value = ViewerCommandActions
}

extension FocusedValues {
    var viewerCommands: ViewerCommandActions? {
        get { self[ViewerCommandsKey.self] }
        set { self[ViewerCommandsKey.self] = newValue }
    }
}

struct ViewerCommands: Commands {
    @FocusedValue(\.viewerCommands) private var viewer

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import PDF…") { viewer?.importDocument() }
                .keyboardShortcut("o")
            Button("Documents…") { viewer?.showLibrary() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("Page") {
            Group {
            Button("Next Page") { viewer?.perform(.nextPage) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Page") { viewer?.perform(.previousPage) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("First Page") { viewer?.perform(.firstPage) }
            Button("Last Page") { viewer?.perform(.lastPage) }
            Button("Go to Page…") { viewer?.goToPage() }
                .keyboardShortcut("l")
            Button("Fit Page") { viewer?.fitPage() }.keyboardShortcut("0")
            }
            .disabled(viewer?.hasDocument != true)
        }
        CommandGroup(replacing: .toolbar) {
            Button(viewer?.controlsVisible == false ? "Show Controls" : "Hide Controls") { viewer?.toggleControls() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(viewer?.hasDocument != true)
        }
    }
}
