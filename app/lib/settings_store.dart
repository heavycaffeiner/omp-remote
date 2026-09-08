import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _themeChoiceKey = 'omp.remote.themeChoice';

/// Appearance modes offered in Settings.
enum AppThemeChoice {
  /// Follow the platform light/dark setting, using the app's own palette.
  system,
  light,
  dark,

  /// Material You: the palette comes from the device wallpaper. Falls back to
  /// the app's own on a device that supplies no wallpaper scheme.
  materialYou;

  String get label => switch (this) {
    AppThemeChoice.system => 'System',
    AppThemeChoice.light => 'Light',
    AppThemeChoice.dark => 'Dark',
    AppThemeChoice.materialYou => 'Material You',
  };

  String get description => switch (this) {
    AppThemeChoice.system => 'Follow the system light and dark setting',
    AppThemeChoice.light => 'Always light',
    AppThemeChoice.dark => 'Always dark',
    AppThemeChoice.materialYou => 'Colours taken from your wallpaper',
  };

  IconData get icon => switch (this) {
    AppThemeChoice.system => Icons.brightness_auto_outlined,
    AppThemeChoice.light => Icons.light_mode_outlined,
    AppThemeChoice.dark => Icons.dark_mode_outlined,
    AppThemeChoice.materialYou => Icons.palette_outlined,
  };

  /// The brightness this choice pins, or null to follow the platform.
  Brightness? get pinnedBrightness => switch (this) {
    AppThemeChoice.light => Brightness.light,
    AppThemeChoice.dark => Brightness.dark,
    AppThemeChoice.system || AppThemeChoice.materialYou => null,
  };

  bool get usesDynamicColor => this == AppThemeChoice.materialYou;
}

/// Preferences that outlive every session and are read during the first
/// frame, before any connection exists.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs) : _themeChoice = _readThemeChoice(_prefs);

  static Future<SettingsStore> load() async =>
      SettingsStore(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  AppThemeChoice _themeChoice;
  AppThemeChoice get themeChoice => _themeChoice;

  Future<void> setThemeChoice(AppThemeChoice choice) async {
    if (choice == _themeChoice) return;
    _themeChoice = choice;
    notifyListeners();
    await _prefs.setString(_themeChoiceKey, choice.name);
  }
}

/// Reads the stored choice, tolerating a value written by a newer build.
AppThemeChoice _readThemeChoice(SharedPreferences prefs) {
  final stored = prefs.getString(_themeChoiceKey);
  for (final choice in AppThemeChoice.values) {
    if (choice.name == stored) return choice;
  }
  return AppThemeChoice.system;
}
