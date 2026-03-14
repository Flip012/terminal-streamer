import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';
import '../models/terminal_session.dart';
import '../services/terminal_service.dart';
import '../services/notification_service.dart';

class TerminalScreen extends StatefulWidget {
  final ServerConfig config;
  final TerminalSessionInfo session;

  const TerminalScreen({
    super.key,
    required this.config,
    required this.session,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with WidgetsBindingObserver {
  late final Terminal _terminal;
  late final TerminalService _terminalService;
  final _terminalController = TerminalController();
  final _focusNode = FocusNode();
  bool _isInForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.instance.requestPermission();

    _terminal = Terminal(
      maxLines: 10000,
    );
    _terminal.resize(widget.session.cols, widget.session.rows);

    _terminalService = TerminalService(
      config: widget.config,
      sessionId: widget.session.id,
      terminal: _terminal,
      onInputRequired: _onInputRequired,
    );
    _terminalService.connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isInForeground = state == AppLifecycleState.resumed;
  }

  void _onInputRequired(String prompt) {
    if (!_isInForeground) {
      NotificationService.instance.show(
        title: 'Terminal: ${widget.session.title}',
        body: prompt,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _terminalService.dispose();
    _terminalController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const terminalStyle = TerminalStyle(
      fontSize: 14,
      fontFamily: 'Fira Code',
      fontFamilyFallback: [
        'Consolas',
        'Courier New',
        'monospace',
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.title),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'ctrl_c':
                  _terminal.keyInput(TerminalKey.keyC, ctrl: true);
                  break;
                case 'ctrl_d':
                  _terminal.keyInput(TerminalKey.keyD, ctrl: true);
                  break;
                case 'ctrl_z':
                  _terminal.keyInput(TerminalKey.keyZ, ctrl: true);
                  break;
                case 'tab':
                  _terminal.keyInput(TerminalKey.tab);
                  break;
                case 'esc':
                  _terminal.keyInput(TerminalKey.escape);
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'ctrl_c', child: Text('Ctrl+C')),
              const PopupMenuItem(value: 'ctrl_d', child: Text('Ctrl+D')),
              const PopupMenuItem(value: 'ctrl_z', child: Text('Ctrl+Z')),
              const PopupMenuItem(value: 'tab', child: Text('Tab')),
              const PopupMenuItem(value: 'esc', child: Text('Esc')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: TerminalView(
          _terminal,
          controller: _terminalController,
          autofocus: true,
          focusNode: _focusNode,
          textStyle: terminalStyle,
        ),
      ),
    );
  }
}
