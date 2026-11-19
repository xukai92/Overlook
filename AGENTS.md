# Overlook agent handoff

## Purpose and current behavior

This is a native Swift/SwiftUI macOS client for GL.iNet GLKVM/Comet. Read
`README.md` for setup and controls. The fork adds:

- Per-host opt-in for self-signed/expired/mismatched device TLS certificates;
  authenticated sessions validate certificates by default.
- Mac-to-Mac shortcut forwarding with a system event tap, an app-local fallback,
  visible permission status, and ordered HID key delivery.
- Control+Option+Escape to release shortcut forwarding; held remote keys are
  released when capture pauses or the app loses focus.
- A Wake display action using a brief Shift pulse through the HTTP HID API,
  independent of video capture, plus Janus streamer-error retries.
- Local cursor hiding over captured, active video, with restoration on exit,
  focus loss, paused capture, and OCR mode.
- A persistent right sidebar outside the video for capture controls and a live
  in-memory key indicator. The toolbar/fullscreen hover controls toggle sidebar
  visibility, which is remembered. In windowed mode it expands to the right and
  folds back on close, preserving the video area's size and top-left position.
  Snapshot the absolute target BEFORE changing SwiftUI state; rapid toggles use
  the pending target rather than a frame already auto-resized by SwiftUI. Do not
  add width deltas to the post-layout frame (this previously caused growth).
- Native size uses remote pixel dimensions as macOS logical points (1920×1200
  remote becomes a 1920×1200-point video area), with chrome/sidebar added outside.
  Fit to screen is a separate scaled action. Size actions exit fullscreen first.
- Invert scrolling is a per-Mac preference reversing both wheel axes before
  transport; it does not change remote device settings.

## Build and validation

Requires macOS 14+ and full Xcode. Run commands from the repository root.

```sh
xcodebuild -project Overlook.xcodeproj \
  -scheme Overlook \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/overlook-build \
  CODE_SIGNING_ALLOWED=NO build
```

SwiftPM downloads the WebRTC dependency pinned in `Package.resolved`. Keep build
outputs outside the repository. For input changes, also run:

```sh
Tests/run-input-tests.sh
```

These tests compile the actual input manager with a mock transport, without
posting keyboard events or contacting a device. They cover shortcut mapping and
ordering, left/right modifiers, releasing held keys, the live indicator, wake
without video, visible errors, and the escape shortcut. They do not prove that
macOS permissions or system-wide capture work on a particular Mac.

For window/sidebar sizing changes, also run `Tests/run-window-tests.sh`; it
covers repeated sidebar transitions, native logical resolution, and screen fit.

For UI changes, inspect the running app. Check sidebar hide/show repeatedly and
ensure its controls stay outside the video. Check windowed/fullscreen sizing
when relevant. Do not interpret a checked forwarding preference as proof of a
working event tap; use the actual ready status and System/App event indicator.

## Install and launch when requested

Quit the current app before replacing it. A user may be actively controlling a
remote machine; use the local app menu to quit rather than Command+Q, which can
be forwarded to the remote machine.

```sh
ditto /tmp/overlook-build/Build/Products/Debug/Overlook.app /Applications/Overlook.app
codesign --force --deep --sign - /Applications/Overlook.app
codesign --verify --deep --strict /Applications/Overlook.app
open /Applications/Overlook.app
```

This is an ad-hoc development build. Each changed executable can invalidate its
macOS keyboard permission. The user may need to remove the old Overlook entry
and add the current app again in Privacy & Security → Device Control and Data
Access / Accessibility, then click Check access. The app tries HID-level capture
with a session-level fallback and reports whether creating/enabling the tap
actually succeeded. Let the user grant OS permissions; do not edit TCC databases
or silently bypass permission controls.

## Source map and constraints

- `Overlook/InputManager.swift`: capture, permission checks, key mapping,
  modifier release, live diagnostics, and wake action.
- `Overlook/GLKVMClient.swift`: HTTP APIs and binary HID WebSocket transport.
- `Overlook/WebRTCManager.swift`: WebRTC and Janus signaling/retry lifecycle.
- `Overlook/ContentView.swift`: video/sidebar layout and window resize lifecycle.
- `Overlook/WindowGeometry.swift`: deterministic sidebar/native/screen-fit geometry.
- `Overlook/ConnectSheets.swift`: connection forms and shared sidebar controls.
- `Overlook/VideoSurfaceView.swift`: video input routing, OCR, cursor lifecycle.
- `Overlook/Info.plist`: ATS configuration allowing custom trust evaluation;
  per-host opt-in remains enforced by device session delegates.

Do not log/save keystroke history, passwords, auth tokens, or device response
bodies containing secrets. The live key display is transient. Saved device
tokens currently use local UserDefaults rather than Keychain; do not describe
this as hardened credential storage. Device firmware and third-party WebRTC
binaries have not been exhaustively audited.

Git remotes are `origin` (the user's `xukai92/Overlook` fork) and `upstream`
(`rcawston/Overlook`). Check `git status` before editing and preserve existing
work. Do not commit, push, or publish merely because asked for status; do so when
the user requests it. Chat context, installed apps, device credentials, VPN
access, and OS permissions do not travel with a Git clone.
