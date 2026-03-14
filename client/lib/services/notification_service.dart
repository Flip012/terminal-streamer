import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
  }

  void _onNotificationTap(NotificationResponse response) {
    // Tapping the notification brings the app to foreground automatically.
  }

  Future<void> showQuestionNotification({
    required String sessionTitle,
    required String questionText,
    required int sessionHash,
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

    await _plugin.show(
      sessionHash,
      'Claude Code wartet',
      '$sessionTitle: $questionText',
      details,
    );
  }

  Future<void> cancelNotification(int id) async {
    await _plugin.cancel(id);
  }
}
