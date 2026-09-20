import SwiftUI
import UniformTypeIdentifiers
import ShowControlCore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    #endif
    @Bindable var model: ViewerModel
    @Bindable var oscController: OSCClient
    @Bindable var midiController: MIDIController
    @State private var screenAwakeController = ScreenAwakeController()
    @State private var isChoosingDocument = false
    @State private var isShowingSettings = false
    @State private var isShowingMonitor = false
    @State private var isShowingPageEntry = false
    @State private var controlsVisible = false
    @State private var isToolbarHovering = false
    @State private var controlsAutoHideTask: Task<Void, Never>?
    @State private var pageEntry = ""
    @FocusState private var pageEntryFocused: Bool

    var body: some View {
        navigation
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            GeneralSettingsView(model: model, oscController: oscController, midiController: midiController)
        }
        .sheet(isPresented: $isShowingMonitor) {
            MonitorView(midiController: midiController, oscController: oscController)
        }
        .fileImporter(isPresented: $isChoosingDocument, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): model.openDocument(at: url)
            case .failure(let error): model.reportOpenError(error)
            }
        }
        // Handed a PDF by Files or the Finder, Viewtiful opens it like any other show.
        .onOpenURL { model.openDocument(at: $0) }
        .alert("Unable to Complete Action", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.clearPresentedError() } }
        )) {
            Button("OK") { model.clearPresentedError() }
        } message: {
            Text(model.presentedError ?? "")
        }
        .focusedSceneValue(\.viewerCommands, ViewerCommandActions(
            hasDocument: model.hasDocument,
            openDocument: { isChoosingDocument = true },
            openLastDocument: model.openLastDocument,
            canOpenLastDocument: model.canOpenLastDocument,
            recentDocuments: model.recentDocuments,
            openRecentDocument: model.openRecentDocument,
            clearRecentDocuments: model.clearRecentDocuments,
            showMonitors: showMonitors,
            goToPage: showPageEntry,
            controlsVisible: controlsVisible,
            toggleControls: toggleControls,
            perform: model.perform
        ))
        .onChange(of: colorScheme, initial: true) { model.systemIsDark = colorScheme == .dark }
        .onChange(of: scenePhase, initial: true) { updateLifecycle() }
        .onChange(of: model.keepScreenAwake) { updateLifecycle() }
        .onChange(of: model.presentationRequest, initial: true) { presentRequestedSheet() }
        .onChange(of: model.hasDocument) {
            controlsAutoHideTask?.cancel()
            controlsVisible = !model.hasDocument
            updateLifecycle()
        }
        .onChange(of: isShowingPageEntry) {
            if !isShowingPageEntry, controlsVisible {
                recordControlsInteraction()
            }
        }
        .onDisappear {
            controlsAutoHideTask?.cancel()
            model.flushPendingPersistence()
        }
        .task {
            oscController.onAction = model.perform
            midiController.onAction = model.perform
            updateLifecycle()
        }
    }

    @ViewBuilder private var navigation: some View {
        #if os(macOS)
        NavigationStack {
            viewer
                .navigationTitle(model.hasDocument ? model.documentName : "Viewtiful")
                .toolbar { viewerToolbar }
                .scrollEdgeEffectStyle(.soft, for: .top)
        }
        // The stack defines its own safe area region, so the document ignoring the
        // titlebar inset inside it only reaches the top of the window if the stack
        // gives up that inset too.
        .ignoresSafeArea(edges: .top)
        .toolbarVisibility(controlsVisible ? .visible : .hidden, for: .windowToolbar)
        .toolbarBackgroundVisibility(controlsVisible ? .automatic : .hidden, for: .windowToolbar)
        .background {
            TitlebarConfigurator()
            ToolbarHoverMonitor { isHovering in
                isToolbarHovering = isHovering
                if isHovering {
                    showControls()
                } else if !isShowingPageEntry {
                    hideControls()
                }
            }
        }
        #else
        if model.hasDocument {
            documentNavigation
        } else {
            documentLauncher
        }
        #endif
    }

    #if !os(macOS)
    private var documentNavigation: some View {
        DocumentNavigation(controlsVisible: controlsVisible, reduceMotion: reduceMotion) {
            viewer
                .navigationTitle(model.hasDocument ? model.documentName : "Viewtiful")
                .toolbar { viewerToolbar }
                .navigationBarTitleDisplayMode(.inline)
        }
        .ignoresSafeArea()
    }

    /// The system document launcher: Viewtiful's actions on a card above the same file
    /// browser Files uses, so shows are opened from where they already live.
    private var documentLauncher: some View {
        DocumentLaunchView("Viewtiful", for: [.pdf]) {
            Button("Open Document") { isChoosingDocument = true }
            if model.canOpenLastDocument {
                Button("Open Last") { model.openLastDocument() }
            }
        } onDocumentOpen: { url in
            // The launcher presents this itself once a file is picked from the browser.
            // Loading it into the model then promotes the viewer to the scene's root.
            documentNavigation
                .task(id: url) { model.openDocument(at: url) }
        }
        //.documentLaunchSubtitle("xxx")
    }
    #endif

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
                                reduceMotion: reduceMotion,
                                onPageTurn: turnPage,
                                onGoToPage: showPageEntry)
                        .accessibilityLabel("\(model.documentName), page \(model.displayedPageNumber) of \(model.pageCount)")
                        .simultaneousGesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    handleDocumentTap(at: value.location, in: proxy.size)
                                }
                        )
                } else {
                    // The Mac has no document launcher scene, so this stands in for it with
                    // the same two choices the iOS launch card offers.
                    ContentUnavailableView {
                        Label("Open a Show Document", systemImage: "doc.richtext")
                    } actions: {
                        Button("Open Document", systemImage: "folder") { isChoosingDocument = true }
                            .buttonStyle(.borderedProminent)
                        if model.canOpenLastDocument {
                            Button("Open Last", systemImage: "clock.arrow.circlepath") { model.openLastDocument() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Fit the document to the whole viewport, including the area beneath controls.
        #if os(macOS)
        .ignoresSafeArea(edges: .top)
        #else
        .ignoresSafeArea()
        #endif
        // Keep a slim edge free of app gestures so the system resize target remains easy to reach.
        .contentShape(Rectangle().inset(by: 8))
        .gesture(DragGesture(minimumDistance: 40).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            turnPage(value.translation.width < 0 ? .nextPage : .previousPage)
        })
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { key in
            guard !isShowingSettings, !isShowingMonitor, !isChoosingDocument, !isShowingPageEntry,
                  key.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
            switch key.key {
            case .rightArrow: turnPage(.nextPage)
            case .leftArrow: turnPage(.previousPage)
            case .space: turnPage(key.modifiers.contains(.shift) ? .previousPage : .nextPage)
            case .home: turnPage(.firstPage)
            case .end: turnPage(.lastPage)
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
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
    }

    private var controlsAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: ShowControlMotion.controlsFadeDuration)
    }

    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("Open Document…", systemImage: "folder") { isChoosingDocument = true }
                if model.hasDocument {
                    // The only route back to the launcher once a show is on screen.
                    Button("Close Document", systemImage: "xmark") { model.closeDocument() }
                }
                if !model.recentDocuments.isEmpty {
                    Section("Recent") {
                        ForEach(model.recentDocuments) { recent in
                            Button(recent.displayName) { model.openRecentDocument(recent) }
                        }
                    }
                }
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a show document")
            .fadesWithControls(controlsVisible, animation: controlsAnimation)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("PDF Appearance") {
                    Picker("Colors", selection: $model.pdfColorAppearance) {
                        Label("Match System", systemImage: "circle.lefthalf.filled")
                            .tag(PDFColorAppearance.matchSystem)
                        Label("Normal", systemImage: "sun.max").tag(PDFColorAppearance.normal)
                        Label("Inverted", systemImage: "moon").tag(PDFColorAppearance.inverted)
                    }
                    .pickerStyle(.inline)
                }
                Button("Hide Controls", systemImage: "eye.slash", action: hideControls)
            } label: {
                Label("Viewer Options", systemImage: "slider.horizontal.3")
            }
            .disabled(!model.hasDocument)
            .help("PDF appearance and viewer controls")
            .fadesWithControls(controlsVisible, animation: controlsAnimation)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Monitors", systemImage: "waveform.path.ecg", action: showMonitors)
                .help("Open MIDI and OSC monitors (Command-Shift-M)")
                .fadesWithControls(controlsVisible, animation: controlsAnimation)
            Button("Settings", systemImage: "gearshape") {
                #if os(macOS)
                openSettings()
                #else
                isShowingSettings = true
                #endif
            }
            .help("Open Settings")
            .fadesWithControls(controlsVisible, animation: controlsAnimation)
        }
        .sharedBackgroundVisibility(.hidden)
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

    private func presentRequestedSheet() {
        guard let request = model.takePresentationRequest() else { return }

        switch request {
        case .openDocument:
            isChoosingDocument = true
        }
    }

    private func turnPage(_ action: ViewtifulAction) {
        model.perform(action)
        if controlsVisible {
            recordControlsInteraction()
        }
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
        controlsAutoHideTask?.cancel()
        controlsAutoHideTask = nil
        withAnimation(controlsAnimation) {
            controlsVisible = false
        }
        isShowingPageEntry = false
        pageEntryFocused = false
        pageEntry = ""
    }

    private func toggleControls() {
        guard model.hasDocument else { return }
        if controlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    private func showControls() {
        if !controlsVisible {
            withAnimation(controlsAnimation) {
                controlsVisible = true
            }
        }
        recordControlsInteraction()
    }

    private func recordControlsInteraction() {
        controlsAutoHideTask?.cancel()
        guard controlsVisible, model.hasDocument, !isShowingPageEntry, !isToolbarHovering else { return }

        controlsAutoHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }

            guard !Task.isCancelled, controlsVisible, !isShowingPageEntry, !isToolbarHovering else { return }
            hideControls()
        }
    }

    private var isValidPage: Bool {
        guard let page = Int(pageEntry), model.pageCount > 0 else { return false }
        return (1...model.pageCount).contains(page)
    }

    private func showPageEntry() {
        guard model.hasDocument else { return }
        showControls()
        pageEntry = String(model.displayedPageNumber)
        isShowingPageEntry = true
    }

    private func showMonitors() {
        #if os(macOS)
        openWindow(id: "monitors")
        #else
        isShowingMonitor = true
        #endif
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

#if os(macOS)
/// Observes AppKit mouse events so the hover target includes the actual window titlebar,
/// where the macOS toolbar is rendered rather than in the SwiftUI content view.
private struct ToolbarHoverMonitor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> MonitoringView {
        MonitoringView(onChange: onChange)
    }

    func updateNSView(_ view: MonitoringView, context: Context) {
        view.onChange = onChange
        view.installMonitorIfNeeded()
    }

    final class MonitoringView: NSView {
        var onChange: (Bool) -> Void
        private var eventMonitor: Any?
        private var reported: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("ToolbarHoverMonitor is not loaded from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitorIfNeeded()
        }

        func installMonitorIfNeeded() {
            guard eventMonitor == nil, window != nil else { return }

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let isInToolbar = event.locationInWindow.y >= window.contentLayoutRect.maxY
                // This runs for every mouse move. Reporting each one would churn the
                // viewer's state, and with it the whole view body, as the pointer travels.
                if isInToolbar != self.reported {
                    self.reported = isInToolbar
                    self.onChange(isInToolbar)
                }
                return event
            }
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }
    }
}

/// Keeps the document beneath the native window toolbar.
private struct TitlebarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ReportingView { ReportingView() }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.configureWindow()
    }

    final class ReportingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        /// Without a full-size content view AppKit lays the content out below the
        /// titlebar, so every toolbar toggle resizes it — and the document with it.
        func configureWindow() {
            guard let window else { return }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
        }

    }
}
#endif

#if !os(macOS)
/// A permanent system navigation bar above the full-size document. Changing alpha
/// fades its buttons and glass together without changing the PDF's layout guides.
private struct DocumentNavigation<Content: View>: UIViewControllerRepresentable {
    let controlsVisible: Bool
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> UINavigationController {
        let host = DocumentHostingController(rootView: content())
        let navigation = UINavigationController(rootViewController: host)
        navigation.loadViewIfNeeded()
        host.setControlsVisible(controlsVisible, animated: false)
        return navigation
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        guard let host = navigation.viewControllers.first as? DocumentHostingController<Content> else { return }
        host.rootView = content()
        host.setControlsVisible(controlsVisible, animated: !reduceMotion && !context.transaction.disablesAnimations)
    }
}

private final class DocumentHostingController<Content: View>: UIHostingController<Content> {
    private var controlsVisible: Bool?
    private weak var pdfScrollView: UIScrollView?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // PDFKit owns (and can replace) its scroll view. Register it with UIKit's
        // native bar machinery instead of drawing a blur over the document ourselves.
        guard let scrollView = findPDFView(in: view)?.contentScrollView,
              scrollView !== pdfScrollView else { return }
        pdfScrollView = scrollView
        scrollView.topEdgeEffect.style = .soft
        scrollView.topEdgeEffect.isHidden = controlsVisible != true
        setContentScrollView(scrollView, for: .top)
    }

    func setControlsVisible(_ visible: Bool, animated: Bool) {
        guard let bar = navigationController?.navigationBar,
              controlsVisible != visible else { return }
        let hasPresentedControls = controlsVisible != nil
        controlsVisible = visible
        bar.isUserInteractionEnabled = visible
        bar.accessibilityElementsHidden = !visible
        let changes = {
            bar.alpha = visible ? 1 : 0
            self.pdfScrollView?.topEdgeEffect.isHidden = !visible
        }
        if animated && hasPresentedControls {
            UIView.animate(withDuration: 0.18, delay: 0,
                           options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction],
                           animations: changes)
        } else {
            changes()
        }
    }

    private func findPDFView(in view: UIView) -> FitPDFView? {
        if let pdf = view as? FitPDFView { return pdf }
        for child in view.subviews {
            if let pdf = findPDFView(in: child) { return pdf }
        }
        return nil
    }
}
#endif

private extension View {
    /// The bar's own alpha only reaches what the system draws inside it — its
    /// background and title. Toolbar items are rendered separately and outlive that
    /// fade, so their content is faded here. The animation is attached rather than
    /// inherited because the transaction driving `controlsVisible` does not reach
    /// content the system hosts outside the view tree.
    func fadesWithControls(_ visible: Bool, animation: Animation?) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(animation, value: visible)
    }
}

struct ViewerCommandActions {
    let hasDocument: Bool
    let openDocument: () -> Void
    let openLastDocument: () -> Void
    let canOpenLastDocument: Bool
    let recentDocuments: [RecentDocument]
    let openRecentDocument: (RecentDocument) -> Void
    let clearRecentDocuments: () -> Void
    let showMonitors: () -> Void
    let goToPage: () -> Void
    let controlsVisible: Bool
    let toggleControls: () -> Void
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
    let requestPresentation: (ViewerPresentationRequest) -> Void
    let openViewer: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Document…") {
                requestPresentation(.openDocument)
                openViewer()
            }
            .keyboardShortcut("o")

            Button("Open Last") {
                openViewer()
                viewer?.openLastDocument()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(viewer?.canOpenLastDocument != true)

            Menu("Open Recent") {
                ForEach(viewer?.recentDocuments ?? []) { recent in
                    Button(recent.displayName) {
                        openViewer()
                        viewer?.openRecentDocument(recent)
                    }
                }
                Divider()
                Button("Clear Menu") { viewer?.clearRecentDocuments() }
            }
            .disabled(viewer?.recentDocuments.isEmpty != false)
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
            }
            .disabled(viewer?.hasDocument != true)
        }
        CommandGroup(replacing: .toolbar) {
            Button(viewer?.controlsVisible == false ? "Show Controls" : "Hide Controls") { viewer?.toggleControls() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(viewer?.hasDocument != true)
            Button("Show Monitors") { viewer?.showMonitors() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}
