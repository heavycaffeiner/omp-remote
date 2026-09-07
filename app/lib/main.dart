import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'pairing.dart';
import 'profile_store.dart';
import 'screens/connection_screen.dart';
import 'screens/pairing_review_screen.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final profileStore = await ProfileStore.load();
  runApp(RemoteOmpApp(profileStore: profileStore));
}

class RemoteOmpApp extends StatefulWidget {
  const RemoteOmpApp({required this.profileStore, super.key});

  final ProfileStore profileStore;

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
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Remote-OMP',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: ConnectionScreen(profileStore: widget.profileStore),
    );
  }
}

ThemeData _buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final seed = const Color(0xFF2F6FED);
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  ).copyWith(error: isDark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: const OutlineInputBorder(),
      filled: true,
      fillColor: isDark
          ? scheme.surfaceContainerHighest
          : scheme.surfaceContainerLow,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(minimumSize: const Size(64, 48)),
    ),
    visualDensity: VisualDensity.adaptivePlatformDensity,
  );
}
