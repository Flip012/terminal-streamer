import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'notification_service.dart';

NotificationService createNotificationService() => WebNotificationService();

class WebNotificationService extends NotificationService {
  bool _granted = false;

  @override
  Future<void> requestPermission() async {
    try {
      final permission = await web.Notification.requestPermission().toDart;
      _granted = permission.toDart == 'granted';
    } catch (_) {
      _granted = false;
    }
  }

  @override
  void show({required String title, required String body}) {
    if (!_granted) return;
    try {
      web.Notification(title, web.NotificationOptions(body: body));
    } catch (_) {}
  }
}
