import 'notification_service_stub.dart'
    if (dart.library.js_interop) 'notification_service_web.dart';

abstract class NotificationService {
  static final NotificationService instance = createNotificationService();

  Future<void> requestPermission();
  void show({required String title, required String body});
}
