# Remote-OMP

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
filter) and `ios/Runner/Info.plist` (the same scheme under
`CFBundleURLTypes`, plus the camera usage string the QR scanner needs).
Regenerating the rest is safe; regenerating those two loses the pairing
entry points.

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
Scanning the code (or tapping the link on the same device) fills in the
relay/direct URL, the token, the role, and the agent id automatically, and
you confirm and save before connecting.

To enter a connection by hand instead, use "Enter manually" and provide:

- **Relay or direct URL**: a `ws://` or `wss://` address. For a relay
  deployment this is the relay's base URL (e.g. `wss://relay.example.com`);
  the app appends `/client` itself. For a direct connection to the plugin's
  own local server, this is `ws://<host>:8788` (default port from the
  plugin), reachable over LAN or Tailscale.
- **Client token**: the control or viewer token for that deployment. This
  field is obscured; the app never displays a token in plain text or logs
  it.
- **Role**: control (can send prompts, answer requests, change settings) or
  viewer (read-only spectator). The role shown here is only a hint for a
  manually entered connection; the authoritative role is whatever the
  server reports back in its `welcome` frame, and the UI always defers to
  that.

Multiple connections can be saved and switched between from the connection
screen.

## Where the token is stored

The client token (and the rest of a saved connection profile) is stored in
`shared_preferences` on the device: an app-private XML file on Android,
`NSUserDefaults` on iOS. It is not encrypted at rest beyond whatever
protection the OS gives app-private storage, is never logged, and is never
rendered in the UI except as a redacted placeholder. Anyone with the
unlocked device can reach it.

## Known environment limitation

This app has not been run on a device or simulator. The machine it was
built on has no Android SDK (`flutter doctor` reports the toolchain as
missing) and iOS requires macOS with Xcode, which was not available.
`flutter analyze` and `flutter test` both pass there, but neither is a
substitute for seeing the UI: the screens have never been rendered on a
real screen. Install the Android SDK, or build on macOS for iOS, and run
it before trusting the layout.
