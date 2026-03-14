import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';
import 'question_detector.dart';
import 'notification_service.dart';

class TerminalService with WidgetsBindingObserver {
  final ServerConfig config;
  final String sessionId;
  final String sessionTitle;
  final Terminal terminal;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _disposed = false;

  final _questionDetector = QuestionDetector();
  Timer? _questionCheckTimer;
  bool _appInBackground = false;

  TerminalService({
    required this.config,
    required this.sessionId,
    required this.terminal,
    this.sessionTitle = 'Terminal',
  });

  void connect() {
    WidgetsBinding.instance.addObserver(this);

    // Periodically check for questions (every 500ms)
    _questionCheckTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _checkForQuestion(),
    );

    final uri = Uri.parse(
      '${config.wsBaseUrl}/ws/terminal/$sessionId?api_key=${Uri.encodeComponent(config.apiKey)}',
    );
    _channel = WebSocketChannel.connect(uri);

    _subscription = _channel!.stream.listen(
      _onMessage,
      onError: _onError,
      onDone: _onDone,
    );

    // Forward terminal input to WebSocket
    terminal.onOutput = (data) {
      if (_channel != null && !_disposed) {
        _channel!.sink.add(jsonEncode({
          'type': 'input',
          'data': data,
        }));
      }
    };

    terminal.onResize = (cols, rows, pixelWidth, pixelHeight) {
      if (_channel != null && !_disposed) {
        _channel!.sink.add(jsonEncode({
          'type': 'resize',
          'cols': cols,
          'rows': rows,
        }));
      }
    };
  }

  void _onMessage(dynamic message) {
    if (_disposed) return;
    try {
      final data = jsonDecode(message as String);
      final type = data['type'] as String?;

      if (type == 'output') {
        final bytes = base64Decode(data['data'] as String);
        final text = utf8.decode(bytes, allowMalformed: true);
        terminal.write(text);
        _questionDetector.onOutput(text);
      } else if (type == 'exit') {
        terminal.write('\r\n[Session ended]\r\n');
      }
    } catch (e) {
      // Ignore malformed messages
    }
  }

  void _onError(dynamic error) {
    if (!_disposed) {
      terminal.write('\r\n[Connection error: $error]\r\n');
    }
  }

  void _onDone() {
    if (!_disposed) {
      terminal.write('\r\n[Disconnected]\r\n');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInBackground = state != AppLifecycleState.resumed;
    if (!_appInBackground) {
      // App came to foreground — cancel any pending notification
      NotificationService.instance.cancelNotification(sessionId.hashCode);
    }
  }

  void _checkForQuestion() {
    if (_disposed) return;
    // Only notify when app is in background
    if (!_appInBackground) return;

    final question = _questionDetector.checkForQuestion();
    if (question != null) {
      NotificationService.instance.showQuestionNotification(
        sessionTitle: sessionTitle,
        questionText: question.length > 150 ? '${question.substring(0, 147)}...' : question,
        sessionHash: sessionId.hashCode,
      );
    }
  }

  void dispose() {
    _disposed = true;
    _questionCheckTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _questionDetector.reset();
    _subscription?.cancel();
    _channel?.sink.close();
  }
}
