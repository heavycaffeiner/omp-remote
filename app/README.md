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

The launcher icon is generated from `assets/icon/omp-remote.svg` (source
of truth) and `assets/icon/omp-remote.png` (a 1024x1024 raster of it, plus
`assets/icon/omp-remote-foreground.png`, the glyph alone inset to the
centre 66 percent for the Android adaptive icon foreground) using the
`flutter_launcher_icons` dev dependency configured in `pubspec.yaml`. The
generated files under `android/app/src/main/res` and
`ios/Runner/Assets.xcassets` are gitignored along with the rest of the
regenerable platform folders, so after `flutter create` regenerates
`android/`, run `dart run flutter_launcher_icons` again to put the icon
back; the release workflow does this automatically.

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

If the camera cannot read the code, "Paste a link" takes the same
`remote-omp://pair?...` string typed or pasted by hand. It carries the URL,
the token, the role, and the session, so one paste is the whole connection.
The role in the link is only a hint; the authoritative role is whatever the
server reports in its `welcome` frame, and the UI defers to that.

When neither is possible, "Enter a code" takes the workstation address and
the six-character code printed alongside the QR.

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
