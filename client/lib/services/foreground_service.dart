import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Manages a foreground service that keeps the app alive while a terminal
/// session is active. The persistent notification shows the current status
/// and is updated with the detected question text when Claude Code is
/// waiting for user input.
class TerminalForegroundService {
  static final TerminalForegroundService instance =
      TerminalForegroundService._();
  TerminalForegroundService._();

  bool _running = false;

  /// Initialise the foreground task configuration. Call once at app startup.
  void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'terminal_foreground',
        channelName: 'Terminal Session',
        channelDescription: 'Hält die Terminal-Verbindung im Hintergrund aktiv',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Start the foreground service when a terminal session is opened.
  Future<void> start({String sessionTitle = 'Terminal'}) async {
    if (_running) return;
    _running = true;

    await FlutterForegroundTask.startService(
      notificationTitle: sessionTitle,
      notificationText: 'Verbunden',
      callback: _foregroundTaskCallback,
    );
  }

  /// Update the notification to show a detected question.
  Future<void> showQuestion(String sessionTitle, String questionText) async {
    if (!_running) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Claude Code wartet',
      notificationText: '$sessionTitle: $questionText',
    );
  }

  /// Reset notification back to normal "connected" state.
  Future<void> clearQuestion(String sessionTitle) async {
    if (!_running) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: sessionTitle,
      notificationText: 'Verbunden',
    );
  }

  /// Stop the foreground service when no terminal session is active.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await FlutterForegroundTask.stopService();
  }

  bool get isRunning => _running;
}

// Top-level callback required by flutter_foreground_task.
// We don't need a long-running isolate – the Dart side already handles the
// WebSocket. The service only exists to keep Android from killing the process.
@pragma('vm:entry-point')
void _foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_NoOpTaskHandler());
}

class _NoOpTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
