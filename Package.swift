// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ViewtifulCore",
    // Swift tools 6.2 cannot express the macOS 27 PackageDescription value;
    // the Xcode app target is the authoritative macOS 27 build boundary.
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ViewtifulCore", path: "Viewtiful", exclude: [
            "Assets.xcassets", "ContentView.swift", "DocumentLibraryView.swift",
            "MyApp.swift", "MonitorView.swift", "PDFPageView.swift", "ScreenAwakeController.swift", "SettingsView.swift"
        ]),
        .testTarget(name: "ViewtifulCoreTests", dependencies: ["ViewtifulCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
