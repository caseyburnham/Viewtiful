# Viewtiful

### A performance-focused PDF viewer for iPadOS and macOS

**Status:** Initial Product Specification  
**Platforms:** iPadOS, macOS  
**Implementation:** 100% Swift using native Apple frameworks  
**Primary Frameworks:** PDFKit, Core MIDI, Network.framework, SwiftUI/UIKit/AppKit/Core Graphics as appropriate  
**Product Category:** Live-performance / show-control utility

---

## 1. Project Summary

Viewtiful is a lightweight, native PDF viewer designed specifically for live performance, rehearsal, broadcast, and show-control workflows.

The application displays one active PDF at a time and allows deterministic page navigation from multiple interchangeable control sources:

- Touch
- Hardware keyboard
- Flic or other HID-compatible buttons
- MIDI
- OSC

Viewtiful is not intended to compete with Preview, Acrobat, ForScore, or general-purpose document-management software.

It is a purpose-built show tool.

The primary use case is an operator displaying a script, score, run sheet, cue sheet, track sheet, or other show document on an iPad or Mac and advancing it from another control surface such as:

- Yamaha RIVAGE
- QLab
- MIDI controller
- Stream Deck configured as keyboard input
- Flic button
- External keyboard
- Another OSC-capable show-control device

The product should feel less like a document application and more like a dedicated piece of professional show-control equipment.

Once configured, Viewtiful should disappear.

---

# 2. Product Principles

Viewtiful should optimize for five things above everything else:

### Reliability

A page-turning application used during a live show must behave predictably for hours at a time.

Unexpected input, malformed network packets, disconnected MIDI devices, unavailable files, backgrounding, orientation changes, or repeated commands must never cause a crash or leave the viewer in an indeterminate state.

### Simplicity

The operator should not need to understand PDF software to use Viewtiful.

Open a document. Configure controls. Run the show.

The application should expose only settings that meaningfully affect that workflow.

### Speed

Launch, document opening, page turns, control response, and HUD presentation should feel effectively instantaneous.

No animation or visual effect should delay a show-control action.

### Native Behavior

Viewtiful should use Apple platform conventions rather than recreating them.

Where possible, it should rely on:

- PDFKit
- Core Graphics
- Core MIDI
- Network.framework
- native document pickers
- native keyboard commands
- native menus
- native accessibility APIs
- native platform storage
- native lifecycle management

Third-party dependencies should be avoided.

### Quietness

During a performance, the application should produce as little UI as possible.

No unnecessary notifications, dialogs, animations, badges, prompts, popups, or status messages should appear over the document.

Configuration information belongs in the HUD or Settings.

---

# 3. Platform Strategy

Viewtiful should share a common Swift core between iPadOS and macOS wherever practical.

The primary performance interface is identical conceptually across platforms:

**Input → Viewtiful Action → PDF Navigation**

Platform-specific UI should remain native rather than forcing identical interfaces onto both platforms.

### iPadOS

Primary target platform.

Optimized for:

- fullscreen PDF display
- touch
- hardware keyboard
- MIDI input
- OSC input
- Flic/HID control
- Files integration

### macOS

Desktop counterpart using the same navigation, MIDI, OSC, document-state, and rendering systems.

Where appropriate, macOS additionally supports:

- standard menu commands
- drag-and-drop PDF import
- keyboard shortcuts
- native window behavior

Viewtiful v1 should remain fundamentally a **single-viewer / single-document-session application**, even on platforms capable of multiple windows.

---

# 4. Technical Constraints

Viewtiful should be built entirely in Swift.

Use Apple frameworks and APIs wherever suitable.

The application should avoid:

- Electron
- Catalyst as a substitute for native platform design
- embedded browser views for document display
- JavaScript
- external MIDI libraries unless absolutely necessary
- external OSC libraries unless a compelling limitation of native implementation is identified
- cross-platform UI frameworks
- unnecessary package dependencies

An OSC implementation may be implemented directly in Swift where necessary.

The architecture should favor small, testable Swift modules rather than a large monolithic application.

---

# 5. Core Architecture

Every input source should invoke the same internal navigation API.

Conceptually:

```text
Touch
Keyboard
Flic / HID
MIDI
OSC
    ↓
Input Adapters
    ↓
Viewtiful Actions
    ↓
Navigation Controller
    ↓
PDF Viewer
```

Core navigation actions:

```text
nextPage
previousPage
goToPage(page)
firstPage
lastPage
```

Input systems must never directly manipulate the PDF view.

This separation allows MIDI, OSC, keyboard, touch, and future control systems to behave identically.

A command received through OSC should produce exactly the same navigation result as the equivalent keyboard command.

---

# 6. Viewer

The viewer is the center of the application.

## Display Behavior

Viewtiful displays:

- one document at a time
- one PDF page at a time
- no continuous vertical document scroll
- no thumbnails during normal performance view

The current page should be centered and fitted cleanly into the available viewport while preserving its aspect ratio.

Changes to:

- window dimensions
- device orientation
- Stage Manager sizing
- fullscreen state

must preserve the current PDF page.

The page should simply be refitted to the new viewport.

### Page Transitions

Page turns should prioritize immediacy over decoration.

Any page-transition animation should be extremely short or disabled entirely.

A control event should never wait for an animation to complete before the application's page state changes.

---

# 7. Navigation

Supported navigation:

- Previous Page
- Next Page
- First Page
- Last Page
- Direct Page Recall

## Wrap Navigation

Sequential navigation wraps.

From the final page:

```text
Next → Page 1
```

From Page 1:

```text
Previous → Final Page
```

Direct page recall does **not** wrap.

For example, requesting Page 84 from a 60-page document is invalid and should be ignored.

It must not:

- wrap
- clamp to Page 60
- produce an alert
- interrupt the viewer

The invalid request may be recorded by diagnostics.

---

# 8. Viewer HUD

Normal performance view should contain no persistent interface chrome.

Tapping or clicking the document reveals a temporary HUD.

The HUD should automatically hide after a short period of inactivity.

Interaction with the HUD resets its hide timer.

The HUD may include:

- document name
- current page
- total pages
- Previous
- Next
- direct page jump
- document picker
- MIDI status
- OSC status
- appearance toggle
- Settings

Example:

```text
Misery Calling Script                     MIDI ●   OSC ●

                         27 / 114

                 ‹                       ›

        Documents     Original / Inverted     Settings
```

Exact visual layout may vary by platform and screen size.

The HUD should be readable in low-light booth environments without overwhelming the document.

---

# 9. Touch Interaction

Default viewer gestures:

- Swipe left → Next Page
- Swipe right → Previous Page
- Tap → Show/Hide HUD

Touch input should feed the same navigation-action system used by external controls.

Gestures should remain deliberately limited.

Viewtiful should avoid accumulating general-purpose PDF-reader gestures that could cause accidental behavior during a show.

Pinch-to-zoom may use native PDF behavior if included, but the default presentation remains **Fit Page**.

Page changes should return the new page to a predictable viewing position.

---

# 10. Keyboard Control

Hardware keyboard input should work on both iPadOS and macOS.

Default bindings:

```text
Right Arrow      Next Page
Left Arrow       Previous Page
Space            Next Page
Shift + Space    Previous Page
Home             First Page
End              Last Page
```

macOS menu commands should expose equivalent actions where appropriate.

Keyboard navigation should continue functioning while the viewer itself has focus.

Typing into a text-entry field such as page jump or Settings must not inadvertently trigger navigation commands.

Repeated keyboard events caused by holding a key should be handled deliberately.

For performance safety, normal page-turn shortcuts should default to **one action per intentional keypress**, rather than rapidly turning pages because a key was held down.

---

# 11. Flic / HID Control

Viewtiful v1 does not require direct integration with the Flic SDK.

Flic buttons configured to produce supported keyboard/HID events should work automatically through Viewtiful's keyboard control layer.

This approach also provides compatibility with other devices capable of sending keyboard commands.

Potential future native Flic integration should remain isolated from navigation logic and simply become another input adapter.

---

# 12. Document Management

Viewtiful maintains a small local library of show documents.

Only one document is active at a time.

Users can:

- import a PDF
- select a previously imported PDF
- remove a PDF from Viewtiful
- switch the active PDF
- reopen the previously active PDF

## Import

On iPadOS, PDFs are imported through the native Files interface.

On macOS, PDFs may additionally be opened through:

- Open
- drag and drop
- Finder

For show reliability, imported documents should preferably be stored in application-managed local storage rather than depending permanently on a removable drive, network share, cloud provider, or security-scoped external URL.

The original file should not be modified.

This means a document remains available during a show even if:

- iCloud becomes unavailable
- Dropbox disconnects
- a USB drive is removed
- the source file is moved

Importing a newer version of a document can be treated as a separate explicit operation rather than silently changing the show document.

---

# 13. Per-Document State

Viewtiful stores persistent state for each document.

At minimum:

- unique internal document identifier
- displayed filename
- imported location/reference
- page count
- last viewed page
- last opened date
- appearance mode if configured per-document

The page index used internally should remain distinct from the page number displayed to the user.

User-facing page numbers are 1-based.

---

# 14. Startup Behavior

Startup page behavior is user-selectable.

### Start at First Page

Opening any PDF begins on Page 1.

### Resume Last Page

Opening a PDF returns to its last successfully viewed page.

If the saved page no longer exists because the PDF has changed, Viewtiful should safely return to Page 1 or the nearest valid page according to a defined restoration rule.

The application should remember the most recently active document.

If that document can no longer be opened, Viewtiful should present the document library instead of entering an error loop.

---

# 15. MIDI

Viewtiful accepts MIDI input through Core MIDI.

The MIDI subsystem should remain active while the application is being used as a viewer and should tolerate devices appearing or disappearing at runtime.

No restart should be required after connecting a MIDI source.

## MIDI Sources

Settings should display available MIDI input endpoints.

Users can enable:

- all sources
- selected sources only

Each source should be displayed using a meaningful system-provided name.

Example:

```text
Network Session 1
RIVAGE PM10
USB MIDI Interface
```

---

# 16. MIDI Channel Filtering

Learned navigation controls support:

```text
Channel: Any
```

or:

```text
Channel: 1–16
```

Channel filtering should occur before navigation actions are generated.

Messages from nonmatching channels should be ignored silently.

---

# 17. MIDI Learn

The following actions can independently learn an incoming MIDI message:

- Next Page
- Previous Page
- First Page
- Last Page

Workflow:

1. User selects **Learn**
2. Viewtiful enters a clearly indicated listening state
3. The next supported MIDI message is captured
4. The binding is stored
5. The binding is displayed in readable form
6. Learn mode ends

Example:

```text
RIVAGE PM10 · Ch 3 · Note 48
```

or:

```text
Network Session · Ch 1 · CC 22
```

Bindings can be:

- relearned
- cleared
- temporarily disabled

Learn mode should have a visible Cancel action.

It should never remain listening indefinitely without clearly indicating that state.

---

# 18. Supported Learned MIDI Events

Initial MIDI Learn support should focus on common deterministic control messages such as:

- Note On
- Control Change
- Program Change where appropriate

Note Off messages should not independently trigger learned page actions unless explicitly supported later.

For Note bindings:

```text
Note On with velocity > 0
```

should be treated as the trigger.

The corresponding Note Off should not cause a second action.

Control Change bindings should use defined trigger semantics so that a single physical button does not generate multiple page turns as its value changes.

The input layer should normalize MIDI into one logical Viewtiful action per intended operator trigger.

---

# 19. MIDI Activity Monitoring

MIDI Settings should provide lightweight diagnostics.

Display:

- available MIDI sources
- enabled sources
- incoming activity indicator
- most recent MIDI message
- source
- channel
- message type
- message data

Example:

```text
Last MIDI Message

RIVAGE PM10
Channel 3
Note On
Note 48
Velocity 127
```

This information is diagnostic only and should not appear over the show document unless the HUD is open.

---

# 20. MIDI Direct Page Recall

Direct page recall is separate from MIDI Learn.

Initial implementation:

```text
MIDI Program Change → PDF Page
```

Configuration:

- Enabled / Disabled
- MIDI source
- MIDI channel
- page offset

Example mapping:

```text
Program 0 → Page 1
Program 1 → Page 2
Program 2 → Page 3
```

or, with a configured offset:

```text
Program 1 → Page 1
```

The UI should make the mapping explicit so operators do not need to reason about MIDI's zero-based Program Change values.

Program Change inherently provides a finite recall range. PDFs beyond the available mapping range remain navigable through sequential controls and OSC.

Invalid page requests are ignored.

---

# 21. MIDI Device Changes

The application must gracefully handle:

- MIDI endpoint disconnect
- endpoint reconnect
- renamed endpoint
- network MIDI session disappearance
- duplicate endpoint names

Loss of a MIDI source must not affect touch, keyboard, OSC, or PDF viewing.

If a configured endpoint disappears, its configuration should remain stored where practical so that reconnecting the device restores operation automatically.

---

# 22. OSC

Viewtiful includes a small OSC server for remote page control.

OSC transport:

```text
UDP
```

OSC packets use normal OSC binary encoding.

**SLIP framing is not used.**

The implementation should follow established OSC message formatting rather than introducing a Viewtiful-specific wire format.

Default namespace:

```text
/viewtiful
```

---

# 23. OSC Commands

Initial command set:

```text
/viewtiful/next
/viewtiful/previous
/viewtiful/first
/viewtiful/last
/viewtiful/page/23
```

`/viewtiful/page/{page_number}` accepts a page number in the address.

Page numbers received over OSC are user-facing, 1-based page numbers.

Example:

```text
/viewtiful/page/{page_number}
```

opens the first page.

Invalid or malformed requests are ignored safely.

Unknown OSC addresses are ignored.

---

# 24. OSC Bundles

OSC bundle support should be implemented where practical.

A bundle containing valid Viewtiful commands should process commands in a deterministic order.

Malformed bundle elements must not invalidate unrelated valid packets or crash the listener.

Viewtiful does not need advanced OSC scheduling or time-tagged show-control execution in v1.

Incoming commands are intended to act when received.

---

# 25. OSC Network Settings

Settings should include:

- OSC Enabled
- UDP listen port
- listen interface when practical
- sender-IP restriction
- current device addresses
- listener status

Default behavior should be easy:

```text
OSC: Enabled
Interface: All Available Interfaces
Port: 53001
Sender Restriction: Off
```

The exact default port may be finalized during implementation.

---

# 26. OSC Diagnostics

Network troubleshooting is a core feature, not an afterthought.

The OSC screen should clearly show:

- listener running / stopped
- configured UDP port
- available local IP addresses
- active interface information where available
- last received OSC address
- last message arguments
- last sender IP
- last-message timestamp
- malformed/rejected packet status where useful

Example:

```text
OSC Listener                 ● Running

Port                         53001

Wi-Fi                        192.168.1.74

Last Message
/viewtiful/page/23

Sender
192.168.1.10

Received
20:41:17
```

This should allow an operator to answer the two most common questions quickly:

**"What IP do I send to?"**

and

**"Is Viewtiful actually receiving anything?"**

---

# 27. Local Network Permissions

On iPadOS, Viewtiful should handle Apple's local-network permission workflow cleanly.

The permission explanation should clearly state why access is needed.

For example:

```text
Viewtiful uses your local network to receive OSC show-control commands.
```

If permission is denied:

- the PDF viewer remains fully functional
- MIDI remains functional
- keyboard remains functional
- the OSC Settings screen clearly explains that network access is unavailable

The application must not repeatedly nag the user.

---

# 28. OSC Error Handling

OSC input must be treated as untrusted data.

The listener must safely reject:

- malformed OSC packets
- invalid type tags
- truncated UDP datagrams
- unsupported argument types
- nonsensical page values
- unknown OSC addresses
- packets from blocked senders

No malformed network input should cause:

- a crash
- navigation corruption
- runaway logging
- a blocked UI thread

---

# 29. Appearance

Viewtiful provides two PDF presentation modes:

```text
Original
Inverted
```

The active appearance mode should be accessible quickly from the viewer HUD.

This is a document-rendering mode, not merely an application dark theme.

---

# 30. Inverted PDF Mode

In Inverted mode:

- PDF page artwork is visually color-inverted
- white backgrounds become dark
- black text becomes light
- embedded artwork is inverted with the PDF page
- PDF annotations retain their original colors

For example, a red annotation remains red rather than becoming cyan.

Conceptually:

```text
Base PDF Content
        ↓
     Invert
        ↓
Annotation Layer
        ↓
Final Display
```

The inversion must therefore occur before annotations are composited.

The implementation may use PDFKit together with Core Graphics or another native rendering path if PDFKit's standard viewer behavior cannot satisfy this requirement directly.

The design requirement is the important part:

**annotations are never subjected to the page inversion effect.**

---

# 31. Application Appearance

Viewtiful itself should follow native system appearance.

Settings and HUD components should work correctly in:

- Light Mode
- Dark Mode

The application's UI appearance is separate from PDF Original/Inverted mode.

A PDF may therefore be displayed in Inverted mode regardless of whether the operating system is using Light or Dark appearance.

---

# 32. Performance Mode

Because Viewtiful is intended for live shows, the application should include show-friendly device behavior.

While a document is actively being used, an optional **Keep Screen Awake** setting should prevent the display from automatically sleeping.

Recommended default:

```text
Keep Screen Awake: On
```

This setting should use native platform mechanisms and should cease applying when Viewtiful is no longer actively being used.

Viewtiful should not perform unnecessary background work simply to prevent sleep.

---

# 33. State and Lifecycle

Viewtiful should tolerate normal application lifecycle events without losing show state.

Examples:

- device rotation
- temporary app backgrounding
- Control Center
- notification overlay
- screen lock
- Stage Manager resize
- Mac window resize

When returning to the application, Viewtiful should restore:

- active document
- current page
- viewer appearance
- control configuration

where appropriate.

Receiving no OSC or MIDI while the operating system has suspended the application is not considered an application failure.

The UI should never falsely imply that iPadOS guarantees background network listening when the application has been suspended.

---

# 34. Persistence

Configuration should be stored locally.

Examples:

- MIDI bindings
- selected MIDI endpoints
- MIDI channel filters
- Program Change mapping
- OSC port
- sender restriction
- startup behavior
- Keep Screen Awake setting
- document metadata
- last viewed pages

No account should be required.

No cloud backend should be required.

No internet connection should be required.

Viewtiful should be fully functional on an isolated show network.

---

# 35. Error Philosophy

During a performance, errors should fail quietly whenever possible.

The viewer should not display modal alerts simply because:

- an OSC packet was malformed
- a MIDI source disappeared
- an invalid page was requested
- an unsupported MIDI message arrived
- an unknown OSC command was received

Instead:

```text
Ignore → Record diagnostic state → Continue operating
```

Modal intervention should be reserved for situations where the user cannot reasonably continue.

For example:

```text
The selected PDF can no longer be opened.
```

Even then, the application should provide a direct route back to document selection.

---

# 36. Concurrency and Command Handling

Navigation commands can arrive from multiple sources almost simultaneously.

For example:

```text
OSC Next
MIDI Next
Keyboard Next
```

The application must maintain a single authoritative navigation state.

Page changes should be serialized and deterministic.

Two commands must never leave the UI believing it is on one page while the document renderer displays another.

Input processing must not block the UI.

Expensive PDF rendering, file access, or network work should not cause external control input to freeze the interface.

---

# 37. Input Independence

Failure of one control system must not affect another.

Examples:

If MIDI disconnects:

```text
Touch ✓
Keyboard ✓
OSC ✓
PDF Viewer ✓
```

If OSC cannot start:

```text
Touch ✓
Keyboard ✓
MIDI ✓
PDF Viewer ✓
```

If a malformed OSC packet arrives:

```text
Everything continues normally.
```

Each adapter should be isolated from the others.

---

# 38. Diagnostics

Viewtiful should provide enough diagnostic information to troubleshoot show-control problems without becoming a developer console.

Diagnostics may include:

### Document

```text
Filename
Page count
Current page
```

### MIDI

```text
Core MIDI status
Available inputs
Enabled inputs
Last received message
Last received time
```

### OSC

```text
Listener status
Port
Local address
Last sender
Last OSC address
Last arguments
Last received time
```

The application should avoid unlimited logging.

Diagnostic history should be bounded so leaving Viewtiful running for a week cannot gradually consume significant memory.

---

# 39. Accessibility

Although designed for professional operators, Viewtiful should use normal Apple accessibility infrastructure.

Controls should provide meaningful accessibility labels.

Examples:

```text
Next Page
Previous Page
Current Page 27 of 114
OSC Listener Running
MIDI Connected
```

The UI should respect:

- Dynamic Type where appropriate
- VoiceOver
- Reduce Motion
- platform contrast conventions

Accessibility support must not interfere with low-chrome performance viewing.

---

# 40. UI Design Language

Viewtiful should look native, restrained, and purpose-built.

Design characteristics:

- generous spacing
- clear typography
- high legibility
- strong state indication
- minimal decorative elements
- no skeuomorphic show-control aesthetic
- no fake hardware panels
- no unnecessary gradients or visual noise

Status should primarily be communicated through:

- text
- native controls
- restrained indicators

The application should look at home on modern Apple platforms without looking like a generic Settings template.

---

# 41. Settings Organization

Suggested Settings structure:

```text
General
 ├─ Startup Behavior
 ├─ Keep Screen Awake
 └─ Viewer Behavior

MIDI
 ├─ Inputs
 ├─ Channel Filter
 ├─ Learned Controls
 ├─ Direct Page Recall
 └─ MIDI Monitor

OSC
 ├─ Enabled
 ├─ Listen Port
 ├─ Interface
 ├─ Sender Restriction
 └─ Network Diagnostics

Documents
 └─ Document Library

About
 ├─ Version
 └─ Diagnostic Information
```

Frequently used performance controls should remain available from the HUD rather than requiring a trip into Settings.

---

# 42. Reliability Requirements

Viewtiful should be designed under the assumption that it may remain open for the duration of:

- rehearsal
- tech
- preview
- performance
- double-show day

The application should tolerate hours of continuous operation.

Specific priorities:

- no accumulating render resources
- no unbounded log buffers
- no repeated network-listener creation
- no duplicated MIDI subscriptions
- no retain cycles caused by control listeners
- no growing page cache without limits
- no runaway timers
- no dependence on internet access

---

# 43. Launch Performance

The app should launch directly into useful state.

Preferred launch behavior when a valid previous document exists:

```text
Launch
↓
Restore Document
↓
Display Page
↓
Controls Ready
```

The user should not need to pass through:

- splash screens
- branding animations
- project selectors
- onboarding screens

on every launch.

Any first-run onboarding should be brief and never shown again unless requested.

---

# 44. V1 Scope

Viewtiful v1 is intentionally a viewer.

## Included

- native PDF viewing
- local show-document library
- Files import
- active-document selection
- per-document page memory
- Start at First / Resume behavior
- touch navigation
- keyboard control
- HID/Flic compatibility
- MIDI input
- MIDI device selection
- MIDI channel filtering
- MIDI Learn
- MIDI activity monitor
- Program Change direct page recall
- OSC over UDP
- OSC page navigation
- OSC direct page recall
- OSC bundle parsing
- sender restriction
- network diagnostics
- PDF inversion
- uninverted annotations
- Keep Screen Awake
- robust state restoration
- iPadOS support
- macOS support

---

# 45. Explicitly Out of Scope for V1

Viewtiful v1 does not include:

- annotation creation
- annotation editing
- handwriting
- highlighting tools
- PDF text editing
- PDF page editing
- PDF creation
- PDF search
- bookmarks
- table-of-contents editing
- cloud accounts
- iCloud library synchronization
- Dropbox integration
- Google Drive integration
- multi-device synchronization
- multi-iPad page following
- collaborative viewing
- cue programming
- timelines
- show files containing multiple PDFs
- outgoing OSC
- outgoing MIDI feedback
- OSC discovery
- MIDI timecode
- MIDI Show Control
- presentation authoring
- integrated QLab control
- proprietary network protocols

These features may be considered later but must not complicate the v1 architecture unnecessarily.

---

# 46. Potential Future Features

The architecture should leave reasonable room for future additions without implementing them prematurely.

Possible future work:

- outgoing OSC page/status feedback
- outgoing MIDI feedback
- Bonjour OSC discovery
- native Flic integration
- Bluetooth remote integrations
- multi-device page synchronization
- dual-page display
- external-display presentation
- multiple PDFs grouped into a show
- named page markers
- PDF metadata inspection
- Apple Shortcuts / App Intents
- URL scheme / deep links
- direct document recall through OSC
- richer MIDI mapping
- Bank Select + Program Change for PDFs over 128 pages

None are required for v1.

---

# 47. Core Acceptance Criteria

Viewtiful v1 should not be considered complete until the following scenarios work reliably.

### PDF

A user can import a PDF, close Viewtiful, reopen it, and return to the expected document and page.

### Touch

A swipe produces exactly one intended page turn.

### Keyboard

An external keyboard can navigate the entire document without touching the screen.

### MIDI

A MIDI control can be learned without manually entering its message values.

Disconnecting and reconnecting the MIDI device does not require restarting Viewtiful.

### MIDI Direct Recall

Sending the configured Program Change recalls the expected page.

An out-of-range page request produces no page change and no interruption.

### OSC

Sending:

```text
/viewtiful/next
```

over UDP advances exactly one page.

Sending:

```text
/viewtiful/page/23
```

opens Page 23.

Malformed OSC traffic cannot crash the application.

### Wraparound

From the last page:

```text
Next → Page 1
```

From Page 1:

```text
Previous → Last Page
```

### Inversion

A page containing:

- black PDF text
- white PDF background
- red annotation

renders in Inverted mode with:

- light text
- dark background
- red annotation

### Isolation

Breaking OSC does not break MIDI.

Breaking MIDI does not break keyboard navigation.

Neither breaks the PDF viewer.

### Long-Run Stability

Viewtiful can remain open and actively receive page commands for the length of a normal performance without accumulating meaningful resource usage or degrading responsiveness.

---

# 48. Definition of Done

A feature is not complete simply because it works in the expected case.

For Viewtiful, implementation should account for:

- normal behavior
- invalid input
- missing input
- duplicate input
- disconnected devices
- reconnection
- lifecycle changes
- persistence
- accessibility
- diagnostics
- recoverable failure
- unit testing where practical

Show software earns trust through boring behavior.

The ideal response from an operator is not:

> "This app has a ton of features."

It is:

> "I forgot it was running."

---

# 49. Product Philosophy

Viewtiful should behave like a dedicated piece of show-control equipment:

**fast, predictable, readable, and quiet.**

Its job is not to help the user manipulate a PDF.

Its job is to put the correct page on the screen every time the operator asks for it.

Once the show begins, the interface should largely disappear and leave the document itself as the focus.

Every new feature should therefore be judged against one question:

**Does this make displaying and controlling a show document more reliable or easier?**

If not, it probably does not belong in Viewtiful.
