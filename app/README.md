# OMPRemote

Flutter client for the omp-remote wire protocol (see `../docs/protocol.md`).
Connects to an omp session either through the relay or directly to the
plugin's local WebSocket server, and lets you read the transcript, send
prompts, answer interactive requests, and change session settings from a
phone. Slash commands are listed for reference but run at the workstation:
the extension API has no way to invoke one remotely.

Targets Android and iOS. The `android/` and `ios/` directories are
regenerable with `flutter create --platforms=android,ios .`; only the two
files carrying hand-written configuration are checked in, namely
`android/app/src/main/AndroidManifest.xml` (the `remote-omp://pair` intent
filter and the app label) and `ios/Runner/Info.plist` (the same scheme
under `CFBundleURLTypes`, the camera usage string the QR scanner needs,
and the display name). Regenerating the rest is safe; regenerating those
two loses the pairing entry points and the display name.

The mark is a single pi on a black square, outlined onto a 1024 grid so it
carries a real letterform and needs no font installed. The outline comes from
STIX Two Math, Copyright (c) 2001-2021 by the STI Pub Companies, under the
SIL Open Font License 1.1 (<https://openfontlicense.org>); the attribution
travels with the path in both files that hold it.
`tool/generate_notification_icon.dart` is the raster source of truth: it
fills that outline and writes `assets/icon/omp-remote.png` (the opaque tile),
`omp-remote-foreground.png` (the glyph alone, scaled to fit the Android
adaptive safe circle), and `ic_notification.png` in every density bucket.
`assets/icon/omp-remote.svg` holds the same path; a change to the mark means
changing both, since no Dart SVG rasterizer is available offline.

`flutter_launcher_icons` then turns those two PNGs into the platform files.
The generated files under `android/app/src/main/res` and
`ios/Runner/Assets.xcassets` are gitignored along with the rest of the
regenerable platform folders, so after `flutter create` regenerates
`android/`, run the generator and then `dart run flutter_launcher_icons` to
put the icon back; the release workflow does this automatically.

## Running on Android

Requires the Android SDK (install via Android Studio, or point
`flutter config --android-sdk <path>` at an existing SDK) and either a
connected device with USB debugging enabled or a running emulator.

```
export PATH="$HOME/development/flutter/bin:$PATH"
cd app
flutter pub get
flutter run -d <device-id>
```

## Running on iOS

Requires macOS with Xcode and CocoaPods. iOS cannot be built from Linux.

```
cd app
flutter pub get
cd ios && pod install && cd ..
flutter run -d <device-id>
```

Running on a physical device needs a signing team set in Xcode under
Runner > Signing & Capabilities.

`flutter devices` lists available targets.

## What to enter on the connection screen

The easiest path is pairing: run `/remote-omp` in an omp session on the
workstation, which prints a QR code and a `remote-omp://pair?...` link.
Scanning the code (or tapping the link on the same device) fills in the URL,
the token, the role, and which session to open, and you confirm and save
before connecting.

If the camera cannot read the code, "Paste a link" takes the same
`remote-omp://pair?...` string typed or pasted by hand. It carries the whole
connection, so one paste is enough. The role in the link is only a hint; the
authoritative role is whatever the server reports in its `welcome` frame,
and the UI defers to that.

When neither is possible, "Enter a code" takes the workstation address and
the six-character code printed alongside the QR. The address is whatever
`/remote-omp` printed, `host` or `host:port`; the port defaults to 8788 when
omitted.

Multiple connections can be saved and switched between from the connection
screen.

## Where the token is stored

The client token (and the rest of a saved connection profile) is stored in
`shared_preferences` on the device: an app-private XML file on Android,
`NSUserDefaults` on iOS. It is not encrypted at rest beyond whatever
protection the OS gives app-private storage, is never logged, and is never
rendered in the UI except as a redacted placeholder. Anyone with the
unlocked device can reach it.

## What the session screen shows

The transcript is a log, not a chat: one left edge with a gutter naming who
produced each line. A tool call is one card carrying its own result, so a
result never repeats below it, and a call that changed a file shows that
file's diff inline with line numbers and per-line markers.

Message text, thinking, notices, and interactive request bodies are rendered
as markdown. Blocks the harness wraps in a tag (`<system-reminder>`,
`<advisory>`, and anything else) are pulled out of the prose and shown as
labelled callouts rather than as stray markup.

Above the transcript: the agent's todo list while it has one, updated as the
list changes rather than at turn boundaries, and one row per spawned subagent
with its status, current tool, and token count.

Below it: messages waiting for the agent to finish. A prompt sent mid-turn is
held rather than delivered, so it can be rewritten or dropped before it runs.
