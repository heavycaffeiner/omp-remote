// Persists saved connection profiles in shared_preferences. Tokens are
// secrets: this module stores them locally on the device but never logs
// them and callers must never render them in plain text.

import 'dart:convert';

import 'package:flutter/foundation.dart';
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
    this.alternates = const [],
    this.agentId,
    this.deviceName,
    this.cwd,
    this.lastUsedAt,
    required this.isDirect,
  });

  final String id;
  final String label;
  final String url;

  /// Other addresses that reach the same session. Kept so a reconnect on a
  /// different network can find the workstation without re-pairing.
  final List<String> alternates;

  final String token;
  final ClientRole role;

  /// Subscribe target: which session on the other end this profile talks to.
  /// Null when pairing did not name one, in which case a lone roster entry
  /// is adopted on connect.
  final String? agentId;
  final String? deviceName;

  /// Working directory of the paired session, when known. Distinguishes
  /// two sessions on the same host (docs/protocol.md, "Discovery").
  final String? cwd;

  /// Epoch milliseconds of the last successful connect, or null if this
  /// profile has never been connected with. Drives most-recently-used
  /// ordering in the connection list.
  final int? lastUsedAt;

  /// Whether this profile dials a workstation directly rather than a relay.
  /// Stored rather than derived: both transports name a session, so the
  /// target does not tell them apart.
  final bool isDirect;

  SavedProfile copyWith({
    String? label,
    String? url,
    List<String>? alternates,
    String? token,
    ClientRole? role,
    String? agentId,
    bool clearAgentId = false,
    String? deviceName,
    String? cwd,
    int? lastUsedAt,
    bool? isDirect,
  }) {
    return SavedProfile(
      id: id,
      label: label ?? this.label,
      url: url ?? this.url,
      alternates: alternates ?? this.alternates,
      token: token ?? this.token,
      role: role ?? this.role,
      agentId: clearAgentId ? null : (agentId ?? this.agentId),
      deviceName: deviceName ?? this.deviceName,
      cwd: cwd ?? this.cwd,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      isDirect: isDirect ?? this.isDirect,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'url': url,
    if (alternates.isNotEmpty) 'alternates': alternates,
    'token': token,
    'role': role == ClientRole.control ? 'control' : 'viewer',
    if (agentId != null) 'agentId': agentId,
    if (deviceName != null) 'deviceName': deviceName,
    if (cwd != null) 'cwd': cwd,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
    'isDirect': isDirect,
  };

  static SavedProfile? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map['id']);
    final label = asString(map['label']);
    final url = asString(map['url']);
    final token = asString(map['token']);
    final role = clientRoleFromJson(map['role']);
    final isDirect = map['isDirect'];
    if (id == null ||
        label == null ||
        url == null ||
        token == null ||
        role == null ||
        isDirect is! bool) {
      return null;
    }
    final rawAlternates = map['alternates'];
    return SavedProfile(
      id: id,
      label: label,
      url: url,
      alternates: rawAlternates is List
          ? [for (final entry in rawAlternates) ?asString(entry)]
          : const [],
      token: token,
      role: role,
      agentId: asString(map['agentId']),
      deviceName: asString(map['deviceName']),
      cwd: asString(map['cwd']),
      lastUsedAt: asInt(map['lastUsedAt']),
      isDirect: isDirect,
    );
  }
}

/// Notifies on every write, so a screen showing the list is correct however
/// the list changed. A deep link pairs without ever passing through the
/// connection screen, which is how a saved connection went missing from the
/// list until the app was restarted.
class ProfileStore extends ChangeNotifier {
  ProfileStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<ProfileStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = ProfileStore(prefs);
    await store.collapseDuplicates();
    return store;
  }

  /// Merges entries that name the same session down to one, keeping the
  /// most recently used. Repairs a device that accumulated a row per
  /// pairing before re-pairing started replacing the existing entry.
  Future<void> collapseDuplicates() async {
    final all = readAll();
    final kept = <SavedProfile>[];
    final seen = <String>{};
    for (final profile in all) {
      final agentId = profile.agentId;
      if (agentId == null) {
        kept.add(profile);
        continue;
      }
      if (seen.add(agentId)) kept.add(profile);
    }
    if (kept.length == all.length) return;
    await _writeAll(kept);
  }

  /// All saved profiles, most-recently-used first. A profile never used
  /// (no recorded connect) sorts after every used one, in insertion order.
  /// The result is modifiable: the mutating methods below build on it.
  List<SavedProfile> readAll() {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null) return <SavedProfile>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return <SavedProfile>[];
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
    notifyListeners();
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

  /// Stores [profile], replacing whatever entry already names the same
  /// session rather than adding a second one.
  ///
  /// One omp session is one connection however many times its pairing link
  /// is scanned; a fresh link only carries a fresh token for the same
  /// session, and several participants can hold one at once. Returns the
  /// entry as stored, which keeps the existing id when one was replaced so
  /// callers do not orphan a renamed connection.
  Future<SavedProfile> upsertForAgent(SavedProfile profile) async {
    final agentId = profile.agentId;
    final all = readAll();
    final index = agentId == null
        ? -1
        : all.indexWhere((p) => p.agentId == agentId);
    if (index < 0) {
      all.add(profile);
      await _writeAll(all);
      return profile;
    }
    final existing = all[index];
    // The user's own label survives a re-pair; everything else comes from
    // the new link, since that is what is current.
    final merged = profile.copyWith(label: existing.label);
    final stored = SavedProfile(
      id: existing.id,
      label: merged.label,
      url: merged.url,
      alternates: merged.alternates,
      token: merged.token,
      role: merged.role,
      agentId: merged.agentId,
      deviceName: merged.deviceName,
      cwd: merged.cwd,
      lastUsedAt: existing.lastUsedAt,
      isDirect: merged.isDirect,
    );
    all[index] = stored;
    await _writeAll(all);
    return stored;
  }

  /// Moves [origin] to the front of a profile's address list, so the next
  /// connect starts with the one that actually answered. A no-op if the
  /// profile is gone or already starts there.
  Future<void> recordWorkingAddress(String id, String origin) async {
    final all = readAll();
    final index = all.indexWhere((p) => p.id == id);
    if (index < 0) return;
    final existing = all[index];
    if (existing.url == origin) return;
    final others = <String>[
      existing.url,
      for (final address in existing.alternates)
        if (address != origin && address != existing.url) address,
    ];
    all[index] = existing.copyWith(url: origin, alternates: others);
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
