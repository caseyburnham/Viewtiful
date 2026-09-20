// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ViewtifulCore",
    // Swift tools 6.2 cannot express the macOS 27 PackageDescription value;
    // the Xcode app target is the authoritative macOS 27 build boundary.
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../ShowControlCore")
    ],
    targets: [
        .target(name: "ViewtifulCore", dependencies: [
            .product(name: "ShowControlCore", package: "ShowControlCore")
        ], path: "Viewtiful", exclude: [
            "Assets.xcassets", "ContentView.swift", "Info.plist", "MonitorView.swift",
            "PDFPageView.swift", "ScreenAwakeController.swift", "SettingsView.swift",
            "ViewtifulApp.swift"
        ]),
        .testTarget(name: "ViewtifulCoreTests", dependencies: ["ViewtifulCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
