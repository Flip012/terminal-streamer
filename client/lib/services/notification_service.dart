import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../main.dart';
import '../models/server_config.dart';
import '../models/terminal_session.dart';
import '../screens/terminal_screen.dart';
import 'api_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  static NotificationService get instance => _instance;
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );
    _initialized = true;

    // Request notification permission (required on Android 13+).
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;

    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final config = ServerConfig.fromJson(data['config'] as Map<String, dynamic>);
      final sessionId = data['sessionId'] as String;

      _navigateToSession(config, sessionId);
    } catch (_) {
      // Malformed payload — just bring app to foreground.
    }
  }

  Future<void> _navigateToSession(ServerConfig config, String sessionId) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;

    try {
      final api = ApiService(config);
      final sessions = await api.listSessions();
      final session = sessions.firstWhere((s) => s.id == sessionId);

      nav.push(
        MaterialPageRoute(
          builder: (_) => TerminalScreen(config: config, session: session),
        ),
      );
    } catch (_) {
      // Session no longer exists or network error — just show the app.
    }
  }

  Future<void> showQuestionNotification({
    required String sessionTitle,
    required String questionText,
    required int sessionHash,
    required String sessionId,
    required ServerConfig config,
  }) async {
    if (!_initialized) return;

    const androidDetails = AndroidNotificationDetails(
      'claude_questions',
      'Claude Code Fragen',
      channelDescription: 'Benachrichtigungen wenn Claude Code auf eine Antwort wartet',
      importance: Importance.high,
      priority: Priority.high,
      ticker: 'Claude Code wartet',
    );

    const details = NotificationDetails(android: androidDetails);

    final payload = jsonEncode({
      'sessionId': sessionId,
      'config': config.toJson(),
    });

    await _plugin.show(
      sessionHash,
      'Claude Code wartet',
      '$sessionTitle: $questionText',
      details,
      payload: payload,
    );
  }

  Future<void> cancelNotification(int id) async {
    await _plugin.cancel(id);
  }
}
