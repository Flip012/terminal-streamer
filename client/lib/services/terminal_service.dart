import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';

class TerminalService {
  final ServerConfig config;
  final String sessionId;
  final Terminal terminal;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _disposed = false;

  TerminalService({
    required this.config,
    required this.sessionId,
    required this.terminal,
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
        terminal.write(String.fromCharCodes(bytes));
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

  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _channel?.sink.close();
  }
}
