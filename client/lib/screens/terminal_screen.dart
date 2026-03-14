import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';
import '../models/terminal_session.dart';
import '../services/terminal_service.dart';

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

class _TerminalScreenState extends State<TerminalScreen> {
  late final Terminal _terminal;
  late final TerminalService _terminalService;
  final _terminalController = TerminalController(
    // Enable drag-to-select text
    pointerInputs: const PointerInputs({PointerInput.tap, PointerInput.scroll}),
  );
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    _terminal = Terminal(
      maxLines: 10000,
    );

    _terminalService = TerminalService(
      config: widget.config,
      sessionId: widget.session.id,
      terminal: _terminal,
      sessionTitle: widget.session.title,
    );

    // Connect after the first frame so TerminalView has been laid out
    // and onResize fires before history data arrives.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _terminalService.connect();
      _startForegroundTask();
    });
  }

  Future<void> _startForegroundTask() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'terminal_foreground',
        channelName: 'Terminal Verbindung',
        channelDescription: 'Hält die Terminal-Verbindung im Hintergrund aktiv',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    FlutterForegroundTask.startService(
      notificationTitle: 'Terminal Streamer',
      notificationText: '${widget.session.title} verbunden',
    );
  }

  void _copySelection() {
    final selection = _terminalController.selection;
    if (selection != null) {
      final text = _terminal.buffer.getText(selection);
      Clipboard.setData(ClipboardData(text: text));
      _terminalController.clearSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kopiert'), duration: Duration(seconds: 1)),
      );
    }
  }

  void _showContextMenu(Offset position) {
    final hasSelection = _terminalController.selection != null;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        if (hasSelection)
          const PopupMenuItem(value: 'copy', child: Text('Kopieren')),
        const PopupMenuItem(value: 'paste', child: Text('Einfügen')),
      ],
    ).then((value) {
      if (value == 'copy') _copySelection();
      if (value == 'paste') _pasteClipboard();
    });
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _terminal.paste(data!.text!);
    }
  }

  @override
  void dispose() {
    FlutterForegroundTask.stopService();
    _terminalService.dispose();
    _terminalController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const terminalStyle = TerminalStyle(
      fontSize: 14,
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: [
        'Courier New',
        'Consolas',
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
                case 'copy':
                  _copySelection();
                  break;
                case 'paste':
                  _pasteClipboard();
                  break;
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
              const PopupMenuItem(value: 'copy', child: Text('Kopieren')),
              const PopupMenuItem(value: 'paste', child: Text('Einfügen')),
              const PopupMenuDivider(),
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
        child: GestureDetector(
          onLongPressStart: (details) {
            _showContextMenu(details.globalPosition);
          },
          child: TerminalView(
            _terminal,
            controller: _terminalController,
            autofocus: true,
            focusNode: _focusNode,
            textStyle: terminalStyle,
          ),
        ),
      ),
    );
  }
}
