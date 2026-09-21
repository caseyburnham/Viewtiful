# Viewtiful

### A native show-control PDF viewer for macOS and iPadOS

Viewtiful puts one show document on screen and lets an operator turn pages from the control surface that is already in the room: touch, keyboard, MIDI, or OSC.

It is designed for scripts, scores, run sheets, cue sheets, track sheets, and other documents that need to be readable and dependable during a live show. Viewtiful is intentionally not a general-purpose PDF library or document manager.

Built with SwiftUI, PDFKit, Core MIDI, and Network.framework. There are no third-party runtime dependencies.

## Highlights

- One-page-at-a-time PDF presentation with fast, deterministic navigation.
- Touch, swipe, hardware keyboard, MIDI, and OSC control paths all feed the same page-navigation model.
- Recent documents, per-document page position, and script-numbering offsets are remembered.
- Optional edge taps, screen-awake behavior, PDF color inversion, page margins, and Reduce Motion support.
- Native macOS menus and windows, including an Activity Log for MIDI and OSC traffic.
- Native iPadOS settings navigation and explicit foreground-only OSC behavior.
- Sandboxed, read-only PDF access: Viewtiful remembers how to reopen a document but does not modify or copy the source PDF.

## Using Viewtiful

1. Choose **Open Document** from the toolbar, or press **⌘O** on macOS.
2. Configure **Settings → MIDI** or **Settings → OSC** if the show uses external control.
3. Hide the controls when the document is ready. The controls reappear when the document is tapped.

Viewtiful remembers the last page for each document by default. Set **Settings → General → Open Documents At** to **First Page** when every performance should start from the front. If the printed script numbering does not start at 1, use **Viewer Options → Page Numbering**; that offset is remembered with the document and is also used by OSC page commands.

### Navigation

| Action | Touch / gesture | Keyboard |
| --- | --- | --- |
| Next page | Swipe left, or tap the right edge when edge navigation is enabled | Right Arrow or Space |
| Previous page | Swipe right, or tap the left edge when edge navigation is enabled | Left Arrow or Shift-Space |
| First page | — | Home |
| Last page | — | End |
| Go to page | Tap the page readout | **⌘L** |
| Show or hide controls | Tap the document center | **⌥⌘T** on macOS |
| Open Activity Log | — | **⇧⌘M** on macOS |

Sequential navigation wraps from the last page to the first and from the first page to the last. Invalid direct page requests are ignored.

## OSC

Turn on OSC in **Settings → OSC**. Viewtiful listens for OSC over UDP; the default port is **53001**. The settings screen shows the active IPv4 addresses that other show-control devices can use.

| OSC address | Behavior |
| --- | --- |
| `/viewtiful/next` | Next page |
| `/viewtiful/previous` | Previous page |
| `/viewtiful/first` | First page |
| `/viewtiful/last` | Last page |
| `/viewtiful/page/{page_number}` | Go to the displayed/script page number |

The original argument form `/viewtiful/page` with one integer argument remains supported. OSC bundles are flattened and handled in packet order; timetags are not scheduled. Unknown or malformed commands are logged and ignored.

For shows where sender identity matters, enable **Restrict to One Sender** and enter the exact sender IP address. On macOS the listener remains available while another app is focused. On iPadOS it stops while the app is backgrounded and restarts when Viewtiful returns to the foreground.

## MIDI

Turn on MIDI in **Settings → MIDI**, choose **All Connected Sources** or one source, and optionally filter by channel.

Each navigation action can be learned independently:

1. Press **Capture** beside an action.
2. Press the hardware control you want to use.
3. Adjust the captured channel, Byte 1, or Byte 2 manually if needed.

Supported messages are Note On with positive velocity, Control Change rising edges, and Program Change. Capturing a control does not turn the page, and one physical control can be assigned to only one navigation action. The Activity Log shows received, ignored, and triggered messages.

Program Change recall is also available without learning individual actions. When enabled, the default mapping is **Program 0 → PDF page 1**; adjust the program offset in Settings when the show uses a different starting point. An explicit learned Program Change mapping takes precedence over recall.

## Development

### Requirements

- Xcode 27 or later
- macOS 27 and iPadOS 27 SDKs
- A sibling checkout of [`ShowControlCore`](../ShowControlCore), as referenced by `Package.swift` and the Xcode project

When working alongside Cuety, open the shared [`ShowControl.xcworkspace`](../ShowControl.xcworkspace). Xcode should not load the same local `ShowControlCore` package through two separate project workspaces at once. Opening `Viewtiful.xcodeproj` by itself is fine when Cuety is closed.

### Build and test

Run the package tests from this directory:

```sh
swift test
```

Build the app targets without code signing:

```sh
xcodebuild \
  -project Viewtiful.xcodeproj \
  -scheme Viewtiful \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Viewtiful.xcodeproj \
  -scheme Viewtiful \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The package tests cover navigation, document restoration, page numbering, MIDI decoding and learning, OSC decoding, malformed packets, bundle ordering, and UDP listener restart behavior. A package-test pass does not replace physical MIDI, live network, iPad lifecycle, accessibility, or long-duration show testing.

## Architecture

```text
Touch · Keyboard · MIDI · OSC
              ↓
       Viewtiful actions
              ↓
       ViewerModel navigation
              ↓
          PDFKit viewer
```

Input adapters do not manipulate the PDF view directly. They emit the same small set of actions—next, previous, first, last, or go to page—so a keyboard press and an OSC cue have identical navigation semantics.

PDF appearance changes are display-only. The source PDF and its stored annotations are left untouched; annotation inversion is an explicit setting, while flattened marks follow the page rendering.
