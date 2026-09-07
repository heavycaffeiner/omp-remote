// Delivery layer for local notifications: plugin initialization, Android
// notification channels, permission handling, the persisted on/off switch,
// and the frame listener that drives NotificationDecider (notification_rules.dart)
// off a live RelayClient. Decision logic itself lives in notification_rules.dart
// and is unit-tested there without any plugin binding; this file cannot be
// exercised by a widget/unit test on this workstation because there is no
// Android SDK and no macOS here to run the platform channel against, so the
// delivery path is verified by reading, not by running.
//
// This is local notification scheduling, not a push service: no Firebase,
// no server, no account. The app already holds a live WebSocket and reacts
// to what arrives on it; it never renders, logs, or notifies a token.

import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_rules.dart';
import 'protocol.dart';
import 'relay_client.dart';

const String _prefsKey = 'remote_omp.notifications_enabled.v1';

/// Persists the user's on/off switch in shared_preferences. Absent (never
/// decided) is distinct from explicitly off: the service treats "never
/// decided" as on by default once permission is granted, and "explicitly
/// off" as off regardless of permission.
class NotificationPreferences {
  NotificationPreferences(this._prefs);

  final SharedPreferences _prefs;

  static Future<NotificationPreferences> load() async =>
      NotificationPreferences(await SharedPreferences.getInstance());

  /// Null means the user has never toggled this: the service defaults it
  /// to on the first time permission is granted.
  bool? get enabled =>
      _prefs.containsKey(_prefsKey) ? _prefs.getBool(_prefsKey) : null;

  Future<void> setEnabled(bool value) => _prefs.setBool(_prefsKey, value);
}

/// One Android notification channel per urgency tier, so a request (which
/// should interrupt with a heads-up alert) and a finished-run or warning
/// (which should not) get genuinely different behavior on Android 8+, where
/// channel importance, not the per-notification priority field, governs
/// heads-up display. Both descriptions are shown to the user in Android's
/// per-app notification settings.
const String _requestChannelId = 'omp_remote_requests';
const String _requestChannelName = 'Interactive requests';
const String _requestChannelDescription =
    'The agent is blocked waiting for you to answer a question.';

const String _statusChannelId = 'omp_remote_status';
const String _statusChannelName = 'Run status';
const String _statusChannelDescription =
    'The agent finished a run, or hit a warning, error, or failed tool call.';

/// The small icon shown in the status bar and notification tray. A
/// monochrome, alpha-only drawable generated from the app icon; see
/// android/app/src/main/res/drawable-*/ic_notification.png.
const String _androidNotificationIcon = 'ic_notification';

/// Drives local notifications off a live [RelayClient]: initializes the
/// plugin once, requests platform permission at the caller's chosen moment,
/// and turns each incoming frame into a show/cancel action via
/// [NotificationDecider]. A process-wide singleton because notification ids
/// and channels are a global namespace on the device; every session screen
/// attaches to and detaches from the same instance as it comes and goes.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final NotificationDecider _decider = NotificationDecider();
  final Map<String, int> _lastSeqByAgent = {};

  NotificationPreferences? _preferences;
  bool _pluginReady = false;
  bool _permissionGranted = false;

  /// Human-readable reason notifications are off, shown in the settings UI.
  /// Null means nothing is preventing them (they may still be off by user
  /// choice; that is not a "reason", just the switch state).
  String? disabledReason;

  /// Called when the user taps a notification, with the session and
  /// (if the notification was about one) pending request to route to. The
  /// currently mounted session screen sets this; only one screen is ever
  /// mounted at a time in this app's navigation, so last-set-wins is
  /// correct in practice; a session screen clears it in dispose.
  void Function(NotificationPayload payload)? onNotificationTap;

  bool get enabled => _permissionGranted && (_preferences?.enabled ?? false);

  Future<void> _ensurePluginReady() async {
    if (_pluginReady) return;
    _pluginReady = true;
    _preferences = await NotificationPreferences.load();

    const androidSettings = AndroidInitializationSettings(
      _androidNotificationIcon,
    );
    // Alert/badge/sound permission is requested explicitly later via
    // requestPermission(), not at initialize time, so the OS prompt never
    // appears before the user has connected to anything.
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
      ),
      onDidReceiveNotificationResponse: _handleResponse,
    );

    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          _requestChannelId,
          _requestChannelName,
          description: _requestChannelDescription,
          importance: Importance.high,
        ),
      );
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          _statusChannelId,
          _statusChannelName,
          description: _statusChannelDescription,
          importance: Importance.defaultImportance,
        ),
      );
      // Permission may already have been granted in a previous app run;
      // areNotificationsEnabled reflects the OS setting without prompting.
      _permissionGranted = await android.areNotificationsEnabled() ?? false;
    } else {
      // iOS/macOS: nothing to query without prompting, so assume not yet
      // granted until requestPermission() is called and succeeds. If the
      // user already granted it in a previous run, requestPermission()
      // returns true again without a second prompt (the OS remembers the
      // decision and only re-prompts after a denial if settings change).
      _permissionGranted = false;
    }
    if (!_permissionGranted) {
      disabledReason = 'Notification permission has not been granted yet.';
    }
  }

  void _handleResponse(NotificationResponse response) {
    final payload = NotificationPayload.decode(response.payload);
    if (payload != null) onNotificationTap?.call(payload);
  }

  /// Requests the platform permission. Call this once the user has actually
  /// connected to a session, not on cold start. On denial, notifications
  /// stay off and [disabledReason] explains why; the app otherwise keeps
  /// working normally. On grant, notifications default to on unless the
  /// user has explicitly turned them off before.
  Future<bool> requestPermission() async {
    await _ensurePluginReady();
    bool? granted;
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      granted = await android.requestNotificationsPermission();
    } else {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final macos = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        granted = await ios.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      } else if (macos != null) {
        granted = await macos.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      }
    }
    _permissionGranted = granted ?? false;
    if (!_permissionGranted) {
      disabledReason =
          'Notification permission was denied. Enable it in system settings to be alerted when the agent needs you.';
      return false;
    }
    disabledReason = null;
    if (_preferences?.enabled == null) {
      // First-ever grant: default the user switch on.
      await _preferences?.setEnabled(true);
    }
    return true;
  }

  /// The user-facing on/off switch, independent of platform permission.
  Future<void> setUserEnabled(bool value) async {
    await _ensurePluginReady();
    await _preferences?.setEnabled(value);
  }

  bool? get userEnabled => _preferences?.enabled;

  /// Updates what is currently visible, so the frame listener can suppress
  /// a notification for a session or request already on screen. Call from
  /// the active session screen's lifecycle and state changes.
  NotificationForegroundState foreground = NotificationForegroundState.none;

  void updateForeground({
    required bool appInForeground,
    String? agentId,
    String? requestId,
  }) {
    foreground = NotificationForegroundState(
      appInForeground: appInForeground,
      foregroundAgentId: agentId,
      foregroundRequestId: requestId,
    );
  }

  /// Subscribes to one [RelayClient]'s frames and turns each into a
  /// notification action. Returns the subscription; the caller (a session
  /// screen) cancels it in dispose. Safe to call before permission is
  /// granted or the user switch is on: [enabled] gates every action, so
  /// attaching early costs nothing and lets a later grant/switch-on start
  /// working immediately without re-attaching.
  StreamSubscription<ServerFrame> attachToClient(
    RelayClient client, {
    required String Function(String agentId) sessionLabel,
  }) {
    unawaited(_ensurePluginReady());
    return client.frames.listen((frame) => _handleFrame(frame, sessionLabel));
  }

  void _handleFrame(
    ServerFrame frame,
    String Function(String agentId) sessionLabel,
  ) {
    // Detect an agent restart the same way session_store.dart does (a seq
    // at or below one already seen), independently, so this service does
    // not depend on session_store.dart's internal state: a restarted
    // agent's new run deserves its own notifications, not silence from
    // stale dedup keys left over from the previous run.
    if (frame case EventFrame(:final agentId, :final seq)) {
      final last = _lastSeqByAgent[agentId];
      if (last != null && seq <= last) {
        _decider.resetForAgent(agentId);
      }
      _lastSeqByAgent[agentId] = seq;
    }

    if (!enabled) return;
    final action = _decider.decide(
      frame,
      sessionLabel: sessionLabel,
      foreground: foreground,
    );
    switch (action) {
      case ShowNotification():
        unawaited(_show(action));
      case CancelNotification():
        unawaited(_plugin.cancel(id: action.id, tag: action.tag));
      case null:
        break;
    }
  }

  Future<void> _show(ShowNotification action) async {
    final isRequest = action.priority == NotificationPriority.high;
    final androidDetails = AndroidNotificationDetails(
      isRequest ? _requestChannelId : _statusChannelId,
      isRequest ? _requestChannelName : _statusChannelName,
      channelDescription: isRequest
          ? _requestChannelDescription
          : _statusChannelDescription,
      importance: isRequest ? Importance.high : Importance.defaultImportance,
      priority: isRequest ? Priority.high : Priority.defaultPriority,
      tag: action.tag,
      groupKey: action.tag,
    );
    final darwinDetails = DarwinNotificationDetails(
      threadIdentifier: action.tag,
      interruptionLevel: isRequest
          ? InterruptionLevel.active
          : InterruptionLevel.passive,
    );
    await _plugin.show(
      id: action.id,
      title: action.title,
      body: action.body,
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      ),
      payload: action.payload.encode(),
    );
  }
}
