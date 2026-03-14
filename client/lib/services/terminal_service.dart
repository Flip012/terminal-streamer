import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';
import '../utils/backoff.dart';
import 'question_detector.dart';
import 'notification_service.dart';
import 'foreground_service.dart';

enum ConnectionStatus { connecting, connected, reconnecting, disconnected }

class TerminalService with WidgetsBindingObserver {
  final ServerConfig config;
  final String sessionId;
  final String sessionTitle;
  final Terminal terminal;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _disposed = false;
  bool _sessionEnded = false;

  /// Observable connection status for UI indicators.
  final connectionStatus = ValueNotifier<ConnectionStatus>(ConnectionStatus.connecting);

  bool get _connected => connectionStatus.value == ConnectionStatus.connected;

  final _questionDetector = QuestionDetector();
  Timer? _questionCheckTimer;
  bool _appInBackground = false;

  // Reconnect state
  static const _maxReconnectAttempts = 10;
  static const _backoffBase = Duration(seconds: 2);
  static const _backoffMax = Duration(seconds: 30);
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  // Heartbeat
  static const _pingInterval = Duration(seconds: 20);
  static const _pongTimeout = Duration(seconds: 10);
  Timer? _pingTimer;
  Timer? _pongTimer;

  // Input buffer – queues input while disconnected
  final _inputBuffer = Queue<String>();
  static const _maxBufferedInputs = 100;
  bool _inputBufferOverflowWarned = false;

  // Network connectivity
  StreamSubscription? _connectivitySubscription;

  TerminalService({
    required this.config,
    required this.sessionId,
    required this.terminal,
    this.sessionTitle = 'Terminal',
  });

  void _setStatus(ConnectionStatus status) {
    if (_disposed || connectionStatus.value == status) return;
    connectionStatus.value = status;
  }

  void connect() {
    WidgetsBinding.instance.addObserver(this);

    // Start foreground service to keep WebSocket alive in background
    TerminalForegroundService.instance.start(sessionTitle: sessionTitle);

    // Periodically check for questions (every 500ms)
    _questionCheckTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _checkForQuestion(),
    );

    // Listen for network connectivity changes
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChanged);

    _connectWebSocket();
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (_disposed || _sessionEnded) return;

    final hasConnection = results.any((r) => r != ConnectivityResult.none);

    if (hasConnection && !_connected && _reconnectAttempts > 0) {
      // Network came back – attempt immediate reconnect
      _reconnectTimer?.cancel();
      terminal.write(
        '\r\n\x1b[33m[Netzwerk verfügbar – verbinde sofort...]\x1b[0m\r\n',
      );
      _connectWebSocket();
    }
  }

  void _connectWebSocket() {
    _subscription?.cancel();
    _stopHeartbeat();
    // Close previous channel without triggering onDone
    try {
      _channel?.sink.close();
    } catch (_) {}

    final uri = Uri.parse(
      '${config.wsBaseUrl}/ws/terminal/$sessionId?api_key=${Uri.encodeComponent(config.apiKey)}',
    );
    _channel = WebSocketChannel.connect(uri);
    _setStatus(_reconnectAttempts > 0
        ? ConnectionStatus.reconnecting
        : ConnectionStatus.connecting);

    _subscription = _channel!.stream.listen(
      _onMessage,
      onError: _onError,
      onDone: _onDone,
    );

    // Forward terminal input to WebSocket (or buffer if disconnected)
    terminal.onOutput = _onTerminalOutput;

    terminal.onResize = (cols, rows, pixelWidth, pixelHeight) {
      _sendJson({
        'type': 'resize',
        'cols': cols,
        'rows': rows,
      });
    };

    // Send initial resize immediately so the server knows our dimensions
    // before sending history.
    _sendJson({
      'type': 'resize',
      'cols': terminal.viewWidth,
      'rows': terminal.viewHeight,
    });
  }

  void _onTerminalOutput(String data) {
    if (_disposed) return;

    if (_connected) {
      _sendJson({'type': 'input', 'data': data});
    } else {
      // Buffer input while disconnected
      if (_inputBuffer.length < _maxBufferedInputs) {
        _inputBuffer.add(data);
        _inputBufferOverflowWarned = false;
      } else if (!_inputBufferOverflowWarned) {
        _inputBufferOverflowWarned = true;
        terminal.write(
          '\r\n\x1b[31m[Eingabepuffer voll – weitere Eingaben gehen verloren]\x1b[0m\r\n',
        );
      }
    }
  }

  void _flushInputBuffer() {
    _inputBufferOverflowWarned = false;
    while (_inputBuffer.isNotEmpty) {
      final data = _inputBuffer.removeFirst();
      _sendJson({'type': 'input', 'data': data});
    }
  }

  bool _sendJson(Map<String, dynamic> data) {
    if (_channel == null || _disposed) return false;
    try {
      _channel!.sink.add(jsonEncode(data));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onMessage(dynamic message) {
    if (_disposed) return;

    final wasDisconnected = !_connected;
    final wasReconnecting = wasDisconnected && _reconnectAttempts > 0;

    // Connection confirmed healthy
    _setStatus(ConnectionStatus.connected);
    _reconnectAttempts = 0;

    // Start heartbeat once on connection, not on every message
    if (wasDisconnected) {
      _startHeartbeat();
      if (wasReconnecting) {
        terminal.write('\r\n\x1b[32m[Verbindung wiederhergestellt]\x1b[0m\r\n');
        TerminalForegroundService.instance.clearQuestion(sessionTitle);
      }
      _flushInputBuffer();
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
        _stopHeartbeat();
        _setStatus(ConnectionStatus.disconnected);
        terminal.write('\r\n\x1b[33m[Session beendet]\x1b[0m\r\n');
        TerminalForegroundService.instance.showQuestion(
          sessionTitle,
          'Session beendet.',
        );
      } else if (type == 'pong') {
        // Pong received – cancel the timeout timer
        _pongTimer?.cancel();
      }
    } catch (e) {
      // Ignore malformed messages
    }
  }

  // -- Heartbeat --

  void _startHeartbeat() {
    _stopHeartbeat();
    _pingTimer = Timer.periodic(_pingInterval, (_) => _sendPing());
  }

  void _stopHeartbeat() {
    _pingTimer?.cancel();
    _pongTimer?.cancel();
  }

  void _sendPing() {
    if (_disposed || !_connected) return;

    final sent = _sendJson({'type': 'ping'});
    if (!sent) return;

    // Start pong timeout – if no pong arrives, connection is dead
    _pongTimer?.cancel();
    _pongTimer = Timer(_pongTimeout, () {
      if (_disposed || _sessionEnded) return;
      _stopHeartbeat();
      _setStatus(ConnectionStatus.reconnecting);
      terminal.write(
        '\r\n\x1b[31m[Keine Antwort vom Server – Verbindung verloren]\x1b[0m\r\n',
      );
      _subscription?.cancel();
      try {
        _channel?.sink.close();
      } catch (_) {}
      _scheduleReconnect();
    });
  }

  void _onError(dynamic error) {
    if (_disposed) return;
    _stopHeartbeat();
    _setStatus(_sessionEnded
        ? ConnectionStatus.disconnected
        : ConnectionStatus.reconnecting);
    final message = _friendlyError(error);
    terminal.write('\r\n\x1b[31m[Verbindungsfehler: $message]\x1b[0m\r\n');
    // Don't schedule reconnect here – onDone will follow
  }

  void _onDone() {
    if (_disposed) return;
    _stopHeartbeat();
    _setStatus(_sessionEnded
        ? ConnectionStatus.disconnected
        : ConnectionStatus.reconnecting);
    if (_sessionEnded) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _sessionEnded) return;

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _setStatus(ConnectionStatus.disconnected);
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
    final delay = backoffDelay(
      attempt: _reconnectAttempts - 1,
      base: _backoffBase,
      max: _backoffMax,
    );
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
        sessionId: sessionId,
        config: config,
      );
    }
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _pongTimer?.cancel();
    _questionCheckTimer?.cancel();
    _connectivitySubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _questionDetector.reset();
    _subscription?.cancel();
    _channel?.sink.close();
    _inputBuffer.clear();
    connectionStatus.dispose();
    TerminalForegroundService.instance.stop();
  }
}
