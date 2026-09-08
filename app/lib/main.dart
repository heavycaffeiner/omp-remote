import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'pairing.dart';
import 'profile_store.dart';
import 'screens/home_shell.dart';
import 'screens/pairing_review_screen.dart';
import 'settings_store.dart';
import 'theme.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final profileStore = await ProfileStore.load();
  final settings = await SettingsStore.load();
  runApp(RemoteOmpApp(profileStore: profileStore, settings: settings));
}

class RemoteOmpApp extends StatefulWidget {
  const RemoteOmpApp({
    required this.profileStore,
    required this.settings,
    super.key,
  });

  final ProfileStore profileStore;
  final SettingsStore settings;

  @override
  State<RemoteOmpApp> createState() => _RemoteOmpAppState();
}

class _RemoteOmpAppState extends State<RemoteOmpApp> {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _wireDeepLinks();
  }

  Future<void> _wireDeepLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handleLink(initial);
    } catch (_) {
      // No initial link available on this platform; not fatal.
    }
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleLink,
      onError: (_) {},
    );
  }

  void _handleLink(Uri uri) {
    final result = PairingPayload.parse(uri.toString());
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    if (result is PairingPayload) {
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PairingReviewScreen(
            payload: result,
            profileStore: widget.profileStore,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(navigator.context)
          .showSnackBar(SnackBar(content: Text('Pairing link error: $result')));
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return ListenableBuilder(
          listenable: widget.settings,
          builder: (context, _) {
            final choice = widget.settings.themeChoice;
            final available = lightDynamic != null || darkDynamic != null;
            final useWallpaper = choice.usesDynamicColor && available;
            // Harmonized so the wallpaper's own hues do not clash with the
            // fixed error and status roles the transcript relies on.
            final light = useWallpaper && lightDynamic != null
                ? buildAppThemeFrom(lightDynamic.harmonized())
                : buildAppTheme(Brightness.light);
            final dark = useWallpaper && darkDynamic != null
                ? buildAppThemeFrom(darkDynamic.harmonized())
                : buildAppTheme(Brightness.dark);
            return MaterialApp(
              navigatorKey: rootNavigatorKey,
              title: 'OMPRemote',
              debugShowCheckedModeBanner: false,
              theme: light,
              darkTheme: dark,
              themeMode: switch (choice.pinnedBrightness) {
                Brightness.light => ThemeMode.light,
                Brightness.dark => ThemeMode.dark,
                null => ThemeMode.system,
              },
              home: HomeShell(
                profileStore: widget.profileStore,
                settings: widget.settings,
                dynamicColorAvailable: available,
              ),
            );
          },
        );
      },
    );
  }
}
