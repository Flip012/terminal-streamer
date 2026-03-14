import 'notification_service.dart';

NotificationService createNotificationService() => StubNotificationService();

class StubNotificationService extends NotificationService {
  @override
  Future<void> requestPermission() async {}

  @override
  void show({required String title, required String body}) {
    // No-op on non-web platforms
  }
}
