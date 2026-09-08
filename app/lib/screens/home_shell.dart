import 'package:flutter/material.dart';

import '../profile_store.dart';
import '../settings_store.dart';
import 'connection_screen.dart';
import 'settings_screen.dart';

/// Two destinations at the app's root: the connections a user pairs with, and
/// the preferences that outlive them. Each tab keeps its own `Scaffold` so it
/// owns its own app bar and actions.
class HomeShell extends StatefulWidget {
  const HomeShell({
    required this.profileStore,
    required this.settings,
    required this.dynamicColorAvailable,
    super.key,
  });

  final ProfileStore profileStore;
  final SettingsStore settings;
  final bool dynamicColorAvailable;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack rather than a swap: switching tabs must not lose the
      // connections list's scroll position or an in-flight connect attempt.
      body: IndexedStack(
        index: _index,
        children: [
          ConnectionScreen(profileStore: widget.profileStore),
          SettingsScreen(
            settings: widget.settings,
            dynamicColorAvailable: widget.dynamicColorAvailable,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.link_outlined),
            selectedIcon: Icon(Icons.link),
            label: 'Connections',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
