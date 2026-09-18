# Viewtiful

A single-document show PDF viewer for macOS and iPadOS, built with SwiftUI, PDFKit, Core MIDI, and Network.framework. No third-party dependencies.

## Operation

Import a PDF using the toolbar or **⌘O** on Mac. Viewtiful keeps a local copy and restores the last document and page. Settings can instead start documents on their first page.

- **Right Arrow / Space:** next page. **Left Arrow / Shift-Space:** previous page.
- **Home / End:** first / last page.
- **⌘L** on Mac, or the page indicator: go to a specific page.
- Tap the document to hide or show all viewer controls. When enabled in Settings, tap the left or right edge to turn the previous or next page.
- Previous, page jump, and Next use native Liquid Glass buttons above the document while controls are visible.
- The Viewer Options toolbar menu provides Zoom Out, Fit Page, Zoom In, PDF color inversion, and Hide Controls.
- **View → Hide/Show Controls** (**⌥⌘T**) toggles the Mac controls.
- Scroll down/up to turn pages. Trackpad momentum does not cause extra turns.
- Sequential navigation wraps; invalid direct page requests do nothing.

The viewer uses standard SwiftUI toolbars, glass buttons, forms, pickers, and file-import controls. Controls fade briefly when shown or hidden, respect Reduce Motion, and never animate page turns. Documents includes search and a visible actions menu for each PDF. Mac Settings uses native tabs; iPad Settings uses a navigation list, and its sheets have explicit Done buttons. On Mac, opening a document fits the window width to the page aspect ratio at the current height, constrained to the screen. Fullscreen and maximized windows retain their size. PDFKit owns rendering; wheel input routes through the shared navigation model.

## OSC

Enable OSC in Settings. The default UDP port is **53001**. Send standard OSC binary messages:

| Address | Argument |
| --- | --- |
| `/viewtiful/next` | None |
| `/viewtiful/previous` | None |
| `/viewtiful/first` | None |
| `/viewtiful/last` | None |
| `/viewtiful/page/{page_number}` | Page number in the address, starting at 1 |

Bundles execute immediately in packet order; timetags are not scheduled. Unknown commands are ignored. The listener remains active when another Mac app has focus. iPad backgrounding stops the listener; returning to the foreground restarts it.

Network.framework handles UDP. A small Swift OSC decoder is necessary because Apple does not ship an OSC API. Packet size, nesting, string padding, and argument boundaries are checked.

## MIDI

Enable MIDI in Settings, choose one connected source or all sources, then use **Capture** beside a navigation action and press a MIDI control. Expand an action to inspect or manually edit its mapping. A learned input is assigned to one action. Its channel, byte 1, and byte 2 are shown in editable fields; for Note On, byte 2 is the captured velocity. Note On with positive velocity, Control Change rising edges, and Program Change are supported. Learning consumes the trigger without turning a page. Release events do not finish learning.

Program Change recall defaults to **Program 0 → Page 1**. An explicit learned Program Change takes precedence over page recall. Devices are discovered with Core MIDI; only successfully connected sources are listed.

## Validation

Open `Viewtiful.xcodeproj` and run the Viewtiful scheme. The project currently targets the 27.0 Apple platforms configured in Xcode.

```sh
swift test
xcodebuild -project Viewtiful.xcodeproj -scheme Viewtiful -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Viewtiful.xcodeproj -scheme Viewtiful -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The Swift package tests the shared core; it does not replace building the Xcode app. Tests use isolated preferences and temporary PDF libraries. Coverage includes malformed OSC, bundle order, actual loopback UDP delivery/restart, MIDI learning and precedence, navigation, and restoration.

## Remaining specification work

This is an initial implementation pass, not a complete v1 release. Direct file dropping, real MIDI hardware reconnection, physical iPad gestures/rotation, VoiceOver operation, and performance-length soak testing still need validation. OSC sender restrictions and local-interface diagnostics are available in Settings.

PDF color inversion is available in Settings → General → PDF Appearance. Annotation colors are preserved by default; enable Invert Annotations to invert them too. Flattened marks invert with the page. These display settings are remembered and do not change the stored PDF.
