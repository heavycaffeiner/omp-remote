// Persists saved connection profiles in shared_preferences. Tokens are
// secrets: this module stores them locally on the device but never logs
// them and callers must never render them in plain text.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

const String _prefsKey = 'remote_omp.profiles.v1';

class SavedProfile {
  const SavedProfile({
    required this.id,
    required this.label,
    required this.url,
    required this.token,
    required this.role,
    this.agentId,
    this.deviceName,
  });

  final String id;
  final String label;
  final String url;
  final String token;
  final ClientRole role;
  final String? agentId;
  final String? deviceName;

  bool get isDirect => agentId == null;

  SavedProfile copyWith({
    String? label,
    String? url,
    String? token,
    ClientRole? role,
    String? agentId,
    bool clearAgentId = false,
    String? deviceName,
  }) {
    return SavedProfile(
      id: id,
      label: label ?? this.label,
      url: url ?? this.url,
      token: token ?? this.token,
      role: role ?? this.role,
      agentId: clearAgentId ? null : (agentId ?? this.agentId),
      deviceName: deviceName ?? this.deviceName,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'url': url,
    'token': token,
    'role': role == ClientRole.control ? 'control' : 'viewer',
    if (agentId != null) 'agentId': agentId,
    if (deviceName != null) 'deviceName': deviceName,
  };

  static SavedProfile? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map['id']);
    final label = asString(map['label']);
    final url = asString(map['url']);
    final token = asString(map['token']);
    final role = clientRoleFromJson(map['role']);
    if (id == null ||
        label == null ||
        url == null ||
        token == null ||
        role == null) {
      return null;
    }
    return SavedProfile(
      id: id,
      label: label,
      url: url,
      token: token,
      role: role,
      agentId: asString(map['agentId']),
      deviceName: asString(map['deviceName']),
    );
  }
}

class ProfileStore {
  ProfileStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<ProfileStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    return ProfileStore(prefs);
  }

  List<SavedProfile> readAll() {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    final result = <SavedProfile>[];
    for (final entry in asList(decoded)) {
      final profile = SavedProfile.fromJson(entry);
      if (profile != null) result.add(profile);
    }
    return result;
  }

  Future<void> _writeAll(List<SavedProfile> profiles) async {
    final encoded = jsonEncode(profiles.map((p) => p.toJson()).toList());
    await _prefs.setString(_prefsKey, encoded);
  }

  Future<void> upsert(SavedProfile profile) async {
    final all = readAll();
    final index = all.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      all[index] = profile;
    } else {
      all.add(profile);
    }
    await _writeAll(all);
  }

  Future<void> remove(String id) async {
    final all = readAll()..removeWhere((p) => p.id == id);
    await _writeAll(all);
  }
}
