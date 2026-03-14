import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';

/// Callback when the terminal output suggests user input is needed.
typedef InputRequiredCallback = void Function(String prompt);

class TerminalService {
  final ServerConfig config;
  final String sessionId;
  final Terminal terminal;
  final InputRequiredCallback? onInputRequired;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _disposed = false;

  /// Buffer of recent output lines to detect input prompts.
  final _recentOutput = StringBuffer();
  Timer? _promptDetectionTimer;

  /// Patterns that indicate the LLM is waiting for user input.
  static final _promptPatterns = [
    RegExp(r'\?\s*$'),                           // ends with ?
    RegExp(r'\(y/n\)\s*:?\s*$', caseSensitive: false),
    RegExp(r'\[Y/n\]\s*:?\s*$'),
    RegExp(r'\[y/N\]\s*:?\s*$'),
    RegExp(r'>\s*$'),                            // prompt ending with >
    RegExp(r':\s*$'),                            // prompt ending with :
    RegExp(r'Enter .+:\s*$', caseSensitive: false),
    RegExp(r'Press .+ to continue', caseSensitive: false),
    RegExp(r'Do you want to', caseSensitive: false),
    RegExp(r'Would you like to', caseSensitive: false),
    RegExp(r'Please (confirm|enter|provide|select|choose)', caseSensitive: false),
  ];

  TerminalService({
    required this.config,
    required this.sessionId,
    required this.terminal,
    this.onInputRequired,
  });

  void connect() {
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
        _detectPrompt(text);
      } else if (type == 'exit') {
        terminal.write('\r\n[Session ended]\r\n');
      }
    } catch (e) {
      // Ignore malformed messages
    }
  }

  /// Strip ANSI escape sequences from text for pattern matching.
  static String _stripAnsi(String text) {
    return text.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '');
  }

  void _detectPrompt(String newOutput) {
    if (onInputRequired == null) return;

    _recentOutput.write(newOutput);

    // Keep only the last 500 chars to avoid unbounded growth
    if (_recentOutput.length > 500) {
      final s = _recentOutput.toString();
      _recentOutput.clear();
      _recentOutput.write(s.substring(s.length - 500));
    }

    // Debounce: wait 800ms after last output before checking.
    // This avoids false positives during rapid output streaming.
    _promptDetectionTimer?.cancel();
    _promptDetectionTimer = Timer(const Duration(milliseconds: 800), () {
      final clean = _stripAnsi(_recentOutput.toString());
      // Check last line(s) of output
      final lastLine = clean.split('\n').last.trim();
      if (lastLine.isEmpty) return;

      for (final pattern in _promptPatterns) {
        if (pattern.hasMatch(lastLine)) {
          onInputRequired!(lastLine.length > 120
              ? '${lastLine.substring(0, 120)}...'
              : lastLine);
          _recentOutput.clear();
          break;
        }
      }
    });
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

  void dispose() {
    _disposed = true;
    _promptDetectionTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
  }
}
