// Persists saved connection profiles in shared_preferences. Tokens are
// secrets: this module stores them locally on the device but never logs
// them and callers must never render them in plain text.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

const String _prefsKey = 'remote_omp.profiles.v1';
const String _recentHostsKey = 'remote_omp.recent_hosts.v1';
const int _maxRecentHosts = 8;

class SavedProfile {
  const SavedProfile({
    required this.id,
    required this.label,
    required this.url,
    required this.token,
    required this.role,
    this.agentId,
    this.deviceName,
    this.cwd,
    this.lastUsedAt,
    this.remoteAgentId,
  });

  final String id;
  final String label;
  final String url;
  final String token;
  final ClientRole role;

  /// Relay subscribe target. Null for a direct connection (which always
  /// has exactly one agent, selected automatically) and for a relay
  /// connection whose target has not been chosen yet.
  final String? agentId;
  final String? deviceName;

  /// Working directory of the paired session, when known. Distinguishes
  /// two sessions on the same host (docs/protocol.md, "Discovery").
  final String? cwd;

  /// Epoch milliseconds of the last successful connect, or null if this
  /// profile has never been connected with. Drives most-recently-used
  /// ordering in the connection list.
  final int? lastUsedAt;

  /// The workstation's own display agent id (e.g.
  /// `kim-thinkpad/omp-remote#k69j`), shown in the connection list.
  /// Distinct from [agentId]: this is display-only and never sent as a
  /// relay subscribe target, since a direct connection has no relay
  /// roster to subscribe within.
  final String? remoteAgentId;

  bool get isDirect => agentId == null;

  SavedProfile copyWith({
    String? label,
    String? url,
    String? token,
    ClientRole? role,
    String? agentId,
    bool clearAgentId = false,
    String? deviceName,
    String? cwd,
    int? lastUsedAt,
    String? remoteAgentId,
  }) {
    return SavedProfile(
      id: id,
      label: label ?? this.label,
      url: url ?? this.url,
      token: token ?? this.token,
      role: role ?? this.role,
      agentId: clearAgentId ? null : (agentId ?? this.agentId),
      deviceName: deviceName ?? this.deviceName,
      cwd: cwd ?? this.cwd,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      remoteAgentId: remoteAgentId ?? this.remoteAgentId,
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
    if (cwd != null) 'cwd': cwd,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
    if (remoteAgentId != null) 'remoteAgentId': remoteAgentId,
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
      cwd: asString(map['cwd']),
      lastUsedAt: asInt(map['lastUsedAt']),
      remoteAgentId: asString(map['remoteAgentId']),
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

  /// All saved profiles, most-recently-used first. A profile never used
  /// (no recorded connect) sorts after every used one, in insertion order.
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
    result.sort((a, b) => (b.lastUsedAt ?? 0).compareTo(a.lastUsedAt ?? 0));
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

  /// Records a connect attempt against [id] for most-recently-used
  /// ordering. A no-op if the profile no longer exists.
  Future<void> recordUsed(String id) async {
    final all = readAll();
    final index = all.indexWhere((p) => p.id == id);
    if (index < 0) return;
    all[index] = all[index].copyWith(
      lastUsedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _writeAll(all);
  }

  Future<void> rename(String id, String newLabel) async {
    final all = readAll();
    final index = all.indexWhere((p) => p.id == id);
    if (index < 0) return;
    all[index] = all[index].copyWith(label: newLabel);
    await _writeAll(all);
  }

  /// Hosts previously entered for discovery or manual connection, most
  /// recent first, so the user does not retype a host they already scanned.
  List<String> readRecentHosts() {
    return _prefs.getStringList(_recentHostsKey) ?? const [];
  }

  Future<void> addRecentHost(String host) async {
    final trimmed = host.trim();
    if (trimmed.isEmpty) return;
    final hosts = readRecentHosts().toList()..remove(trimmed);
    hosts.insert(0, trimmed);
    if (hosts.length > _maxRecentHosts) {
      hosts.removeRange(_maxRecentHosts, hosts.length);
    }
    await _prefs.setStringList(_recentHostsKey, hosts);
  }
}
