import 'package:flutter/material.dart';
import '../models/server_config.dart';
import '../models/terminal_session.dart';
import '../services/api_service.dart';
import 'terminal_screen.dart';
import 'connect_screen.dart';

class SessionsScreen extends StatefulWidget {
  final ServerConfig config;

  const SessionsScreen({super.key, required this.config});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  late final ApiService _api;
  List<TerminalSessionInfo> _sessions = [];
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _api = ApiService(widget.config);
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await _api.listSessions();
      if (mounted) {
        setState(() {
          _sessions = sessions;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _createSession() async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final session = await _api.createSession(title: 'Terminal');
      if (mounted) {
        _openTerminal(session);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _openTerminal(TerminalSessionInfo session) {
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => TerminalScreen(
          config: widget.config,
          session: session,
        ),
      ),
    )
        .then((_) => _refresh());
  }

  Future<void> _confirmDeleteSession(String sessionId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session löschen?'),
        content: const Text('Diese Aktion kann nicht rückgängig gemacht werden.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Löschen', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await _api.deleteSession(sessionId);
        _refresh();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$e'),
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    }
  }

  void _disconnect() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ConnectScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _disconnect,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _creating ? null : _createSession,
        icon: _creating
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.add),
        label: Text(_creating ? 'Erstelle...' : 'New Terminal'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_sessions.isEmpty) {
      return const Center(
        child: Text(
          'No active sessions.\nTap + to create one.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _sessions.length,
        itemBuilder: (context, index) {
          final session = _sessions[index];
          final hasResume = session.claudeResumeId != null;
          return ListTile(
            leading: Icon(
              hasResume ? Icons.smart_toy : Icons.terminal,
              color: session.alive ? Colors.green : Colors.grey,
            ),
            title: Text(session.title),
            subtitle: Text(
              hasResume
                  ? 'Claude Code  ${session.claudeResumeId}'
                  : '${session.shell} - ${session.cols}x${session.rows}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: () => _confirmDeleteSession(session.id),
            ),
            onTap: () => _openTerminal(session),
          );
        },
      ),
    );
  }
}
