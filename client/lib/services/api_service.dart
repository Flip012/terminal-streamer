import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/server_config.dart';
import '../models/terminal_session.dart';

class ApiService {
  final ServerConfig config;
  static const _timeout = Duration(seconds: 10);

  ApiService(this.config);

  /// Quick connectivity check – hits GET /api/sessions with a short timeout.
  Future<void> testConnection() async {
    try {
      final response = await http
          .get(
            Uri.parse('${config.httpBaseUrl}/api/sessions'),
            headers: config.headers,
          )
          .timeout(_timeout);
      if (response.statusCode == 403) {
        throw ApiException('Invalid API key');
      }
      if (response.statusCode != 200) {
        throw ApiException('Server error: ${response.statusCode}');
      }
    } on ApiException {
      rethrow;
    } on Exception catch (e) {
      if (e.toString().contains('TimeoutException')) {
        throw ApiException('Connection timed out – is the server running?');
      }
      throw ApiException('Cannot reach server: $e');
    }
  }

  Future<List<TerminalSessionInfo>> listSessions() async {
    final response = await http
        .get(
          Uri.parse('${config.httpBaseUrl}/api/sessions'),
          headers: config.headers,
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw ApiException('Failed to list sessions: ${response.statusCode}');
    }
    final data = jsonDecode(response.body);
    return (data['sessions'] as List)
        .map((s) => TerminalSessionInfo.fromJson(s))
        .toList();
  }

  Future<TerminalSessionInfo> createSession({
    String? shell,
    int cols = 120,
    int rows = 30,
    String title = '',
  }) async {
    final response = await http
        .post(
          Uri.parse('${config.httpBaseUrl}/api/sessions'),
          headers: {...config.headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            if (shell != null) 'shell': shell,
            'cols': cols,
            'rows': rows,
            'title': title,
          }),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw ApiException('Failed to create session: ${response.statusCode}');
    }
    final data = jsonDecode(response.body);
    return TerminalSessionInfo.fromJson(data['session']);
  }

  Future<void> deleteSession(String sessionId) async {
    final response = await http
        .delete(
          Uri.parse('${config.httpBaseUrl}/api/sessions/$sessionId'),
          headers: config.headers,
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw ApiException('Failed to delete session: ${response.statusCode}');
    }
  }

  Future<void> resizeSession(String sessionId, int cols, int rows) async {
    final response = await http
        .post(
          Uri.parse('${config.httpBaseUrl}/api/sessions/$sessionId/resize'),
          headers: {...config.headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'cols': cols, 'rows': rows}),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw ApiException('Failed to resize session: ${response.statusCode}');
    }
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => 'ApiException: $message';
}
