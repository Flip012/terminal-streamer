import 'package:flutter/material.dart';
import '../models/server_config.dart';
import '../services/api_service.dart';
import '../services/config_storage.dart';
import 'sessions_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8765');
  final _apiKeyController = TextEditingController();
  bool _useTls = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadSavedConfig();
  }

  Future<void> _loadSavedConfig() async {
    final config = await ConfigStorage.load();
    if (config != null && mounted) {
      setState(() {
        _hostController.text = config.host;
        _portController.text = config.port.toString();
        _apiKeyController.text = config.apiKey;
        _useTls = config.useTls;
      });
    }
  }

  Future<void> _connect() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final apiKey = _apiKeyController.text.trim();

    if (host.isEmpty || port == null || apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte alle Felder ausfüllen.')),
      );
      return;
    }

    final config = ServerConfig(
      host: host,
      port: port,
      apiKey: apiKey,
      useTls: _useTls,
    );

    setState(() => _loading = true);

    try {
      // Actually test the connection before navigating
      final api = ApiService(config);
      await api.testConnection();

      await ConfigStorage.save(config);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => SessionsScreen(config: config),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Verbindung fehlgeschlagen: $e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal Streamer'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.terminal, size: 64, color: Colors.green),
            const SizedBox(height: 32),
            TextField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: 'Host / IP',
                hintText: '192.168.1.100',
                prefixIcon: Icon(Icons.computer),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                prefixIcon: Icon(Icons.numbers),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'API Key',
                prefixIcon: Icon(Icons.key),
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Use TLS (HTTPS/WSS)'),
              value: _useTls,
              onChanged: (v) => setState(() => _useTls = v),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _connect,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: Text(_loading ? 'Connecting...' : 'Connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
