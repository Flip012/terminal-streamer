import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/server_config.dart';
import '../models/terminal_session.dart';
import '../utils/backoff.dart';

class ApiService {
  final ServerConfig config;
  static const _timeout = Duration(seconds: 10);
  static const _maxRetries = 3;
  static const _initialRetryDelay = Duration(seconds: 1);

  ApiService(this.config);

  /// Quick connectivity check – hits GET /api/sessions with a short timeout.
  Future<void> testConnection() async {
    final http.Response response;
    try {
      response = await http
          .get(
            Uri.parse('${config.httpBaseUrl}/api/sessions'),
            headers: config.headers,
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw ApiException('Zeitüberschreitung – läuft der Server?');
    } on SocketException catch (e) {
      throw ApiException('Server nicht erreichbar: ${e.message}');
    } catch (e) {
      throw ApiException('Verbindung fehlgeschlagen: $e');
    }

    _checkStatus(response, 'Verbindungstest');
  }

  Future<List<TerminalSessionInfo>> listSessions() async {
    final response = await _get('/api/sessions', 'Sessions laden');
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
    final response = await _post(
      '/api/sessions',
      'Session erstellen',
      body: {
        if (shell != null) 'shell': shell,
        'cols': cols,
        'rows': rows,
        'title': title,
      },
    );
    final data = jsonDecode(response.body);
    return TerminalSessionInfo.fromJson(data['session']);
  }

  Future<void> deleteSession(String sessionId) async {
    await _delete('/api/sessions/$sessionId', 'Session löschen');
  }

  Future<void> resizeSession(String sessionId, int cols, int rows) async {
    await _post(
      '/api/sessions/$sessionId/resize',
      'Terminal-Größe ändern',
      body: {'cols': cols, 'rows': rows},
    );
  }

  // -- internal helpers --

  Future<http.Response> _get(String path, String action) async {
    final response = await _requestWithRetry(
      () => http.get(
        Uri.parse('${config.httpBaseUrl}$path'),
        headers: config.headers,
      ),
      action,
    );
    _checkStatus(response, action);
    return response;
  }

  Future<http.Response> _post(String path, String action,
      {Map<String, dynamic>? body}) async {
    final response = await _requestWithRetry(
      () => http.post(
        Uri.parse('${config.httpBaseUrl}$path'),
        headers: {...config.headers, 'Content-Type': 'application/json'},
        body: body != null ? jsonEncode(body) : null,
      ),
      action,
    );
    _checkStatus(response, action);
    return response;
  }

  Future<http.Response> _delete(String path, String action) async {
    final response = await _requestWithRetry(
      () => http.delete(
        Uri.parse('${config.httpBaseUrl}$path'),
        headers: config.headers,
      ),
      action,
    );
    _checkStatus(response, action);
    return response;
  }

  /// Executes an HTTP request with retry logic and exponential backoff.
  /// Retries on transient errors (timeout, socket, 502/503).
  Future<http.Response> _requestWithRetry(
    Future<http.Response> Function() fn,
    String action,
  ) async {
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        final response = await fn().timeout(_timeout);

        // Retry on transient server errors
        if ((response.statusCode == 502 || response.statusCode == 503) &&
            attempt < _maxRetries) {
          await _retryDelay(attempt);
          continue;
        }

        return response;
      } on TimeoutException {
        if (attempt >= _maxRetries) {
          throw ApiException(
            '$action fehlgeschlagen: Zeitüberschreitung – Server antwortet nicht.',
          );
        }
        await _retryDelay(attempt);
      } on SocketException catch (e) {
        if (attempt >= _maxRetries) {
          throw ApiException(
            '$action fehlgeschlagen: Server nicht erreichbar (${e.message}).',
          );
        }
        await _retryDelay(attempt);
      } catch (e) {
        if (e is ApiException) rethrow;
        if (attempt >= _maxRetries) {
          throw ApiException('$action fehlgeschlagen: $e');
        }
        await _retryDelay(attempt);
      }
    }
    // Should not reach here, but just in case
    throw ApiException('$action fehlgeschlagen nach $_maxRetries Versuchen.');
  }

  Future<void> _retryDelay(int attempt) async {
    await Future.delayed(backoffDelay(
      attempt: attempt,
      base: _initialRetryDelay,
    ));
  }

  void _checkStatus(http.Response response, String action) {
    if (response.statusCode == 200) return;

    switch (response.statusCode) {
      case 403:
        throw ApiException('Ungültiger API-Key.');
      case 404:
        throw ApiException('$action: Nicht gefunden (404).');
      case 500:
        throw ApiException('Serverfehler (500) – bitte Server-Logs prüfen.');
      case 502:
      case 503:
        throw ApiException('Server ist nicht verfügbar (${response.statusCode}).');
      default:
        throw ApiException(
          '$action fehlgeschlagen: HTTP ${response.statusCode}.',
        );
    }
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}
