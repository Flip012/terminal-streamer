import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';
import 'question_detector.dart';
import 'notification_service.dart';
import 'foreground_service.dart';

class TerminalService with WidgetsBindingObserver {
  final ServerConfig config;
  final String sessionId;
  final String sessionTitle;
  final Terminal terminal;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _disposed = false;
  bool _sessionEnded = false;

  final _questionDetector = QuestionDetector();
  Timer? _questionCheckTimer;
  bool _appInBackground = false;

  // Reconnect state
  static const _maxReconnectAttempts = 10;
  static const _initialDelay = Duration(seconds: 2);
  static const _maxDelay = Duration(seconds: 30);
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  TerminalService({
    required this.config,
    required this.sessionId,
    required this.terminal,
    this.sessionTitle = 'Terminal',
  });

  void connect() {
    WidgetsBinding.instance.addObserver(this);

    // Start foreground service to keep WebSocket alive in background
    TerminalForegroundService.instance.start(sessionTitle: sessionTitle);

    // Periodically check for questions (every 500ms)
    _questionCheckTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _checkForQuestion(),
    );

    _connectWebSocket();
  }

  void _connectWebSocket() {
    _subscription?.cancel();
    _channel?.sink.close();

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
        try {
          _channel!.sink.add(jsonEncode({
            'type': 'input',
            'data': data,
          }));
        } catch (_) {
          // Sink closed – reconnect will handle it
        }
      }
    };

    terminal.onResize = (cols, rows, pixelWidth, pixelHeight) {
      if (_channel != null && !_disposed) {
        try {
          _channel!.sink.add(jsonEncode({
            'type': 'resize',
            'cols': cols,
            'rows': rows,
          }));
        } catch (_) {}
      }
    };

    // Send initial resize immediately so the server knows our dimensions
    // before sending history. The terminal has already been laid out at
    // this point (connect() is called in addPostFrameCallback).
    try {
      _channel!.sink.add(jsonEncode({
        'type': 'resize',
        'cols': terminal.viewWidth,
        'rows': terminal.viewHeight,
      }));
    } catch (_) {}
  }

  void _onMessage(dynamic message) {
    if (_disposed) return;

    // Successful message means connection is healthy
    if (_reconnectAttempts > 0) {
      _reconnectAttempts = 0;
      terminal.write('\r\n\x1b[32m[Verbindung wiederhergestellt]\x1b[0m\r\n');
      TerminalForegroundService.instance.clearQuestion(sessionTitle);
    }

    try {
      final data = jsonDecode(message as String);
      final type = data['type'] as String?;

      if (type == 'output') {
        final bytes = base64Decode(data['data'] as String);
        final text = utf8.decode(bytes, allowMalformed: true);
        terminal.write(text);
        _questionDetector.onOutput(text);
      } else if (type == 'exit') {
        _sessionEnded = true;
        terminal.write('\r\n\x1b[33m[Session beendet]\x1b[0m\r\n');
        TerminalForegroundService.instance.showQuestion(
          sessionTitle,
          'Session beendet.',
        );
      }
    } catch (e) {
      // Ignore malformed messages
    }
  }

  void _onError(dynamic error) {
    if (_disposed) return;
    final message = _friendlyError(error);
    terminal.write('\r\n\x1b[31m[Verbindungsfehler: $message]\x1b[0m\r\n');
    // Don't schedule reconnect here – onDone will follow
  }

  void _onDone() {
    if (_disposed || _sessionEnded) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _sessionEnded) return;

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      terminal.write(
        '\r\n\x1b[31m[Verbindung verloren – maximale Versuche erreicht. '
        'Bitte Session neu öffnen.]\x1b[0m\r\n',
      );
      TerminalForegroundService.instance.showQuestion(
        sessionTitle,
        'Verbindung verloren. Bitte Session neu öffnen.',
      );
      return;
    }

    _reconnectAttempts++;
    final delay = _getBackoffDelay(_reconnectAttempts);
    final delaySec = delay.inSeconds;

    terminal.write(
      '\r\n\x1b[33m[Verbindung getrennt – '
      'Wiederverbindung in ${delaySec}s '
      '(Versuch $_reconnectAttempts/$_maxReconnectAttempts)...]\x1b[0m\r\n',
    );
    TerminalForegroundService.instance.showQuestion(
      sessionTitle,
      'Wiederverbindung in ${delaySec}s (Versuch $_reconnectAttempts/$_maxReconnectAttempts)...',
    );

    _reconnectTimer = Timer(delay, () {
      if (_disposed || _sessionEnded) return;
      terminal.write('\x1b[33m[Verbinde...]\x1b[0m\r\n');
      _connectWebSocket();
    });
  }

  Duration _getBackoffDelay(int attempt) {
    // Exponential backoff with jitter: 2s, 4s, 8s, ... capped at 30s
    final baseMs = _initialDelay.inMilliseconds * pow(2, attempt - 1);
    final cappedMs = min(baseMs.toInt(), _maxDelay.inMilliseconds);
    // Add 0-25% jitter to avoid thundering herd
    final jitter = (cappedMs * 0.25 * (DateTime.now().millisecond / 1000)).toInt();
    return Duration(milliseconds: cappedMs + jitter);
  }

  String _friendlyError(dynamic error) {
    final msg = error.toString();
    if (msg.contains('SocketException')) {
      return 'Server nicht erreichbar.';
    }
    if (msg.contains('TimeoutException')) {
      return 'Zeitüberschreitung.';
    }
    if (msg.contains('HandshakeException') || msg.contains('TLS')) {
      return 'TLS-Fehler – stimmt die TLS-Einstellung?';
    }
    if (msg.contains('4003')) {
      return 'Ungültiger API-Key.';
    }
    if (msg.contains('4004')) {
      return 'Session nicht gefunden.';
    }
    return msg;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInBackground = state != AppLifecycleState.resumed;
    if (!_appInBackground) {
      // App came to foreground — cancel any pending notification
      NotificationService.instance.cancelNotification(sessionId.hashCode);
      // Only clear foreground notification if we're connected (not reconnecting)
      if (_reconnectAttempts == 0) {
        TerminalForegroundService.instance.clearQuestion(sessionTitle);
      }
    }
  }

  void _checkForQuestion() {
    if (_disposed) return;
    // Only notify when app is in background
    if (!_appInBackground) return;

    final question = _questionDetector.checkForQuestion();
    if (question != null) {
      final truncated =
          question.length > 150 ? '${question.substring(0, 147)}...' : question;

      // Show in both the foreground service notification and the alert notification
      TerminalForegroundService.instance.showQuestion(sessionTitle, truncated);
      NotificationService.instance.showQuestionNotification(
        sessionTitle: sessionTitle,
        questionText: truncated,
        sessionHash: sessionId.hashCode,
      );
    }
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _questionCheckTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _questionDetector.reset();
    _subscription?.cancel();
    _channel?.sink.close();
    TerminalForegroundService.instance.stop();
  }
}
