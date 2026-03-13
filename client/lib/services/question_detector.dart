/// Detects when Claude Code is asking a question in terminal output.
///
/// Mirrors the server-side detection logic for use in the Flutter client.
class QuestionDetector {
  static final _ansiEscape = RegExp(
    r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?\x07|\x1b[()][AB012]|\x1b\[\??[0-9;]*[hlm]',
  );

  String _buffer = '';
  DateTime _lastOutputTime = DateTime.now();
  bool _notified = false;

  static const maxBuffer = 4096;
  static const idleThreshold = Duration(seconds: 3);

  /// Call this when new terminal output arrives.
  void onOutput(String text) {
    _lastOutputTime = DateTime.now();
    _notified = false;
    _buffer = (_buffer + text);
    if (_buffer.length > maxBuffer) {
      _buffer = _buffer.substring(_buffer.length - maxBuffer);
    }
  }

  /// Call this periodically to check if a question is pending.
  /// Returns the detected question text, or null.
  String? checkForQuestion() {
    if (_notified || _buffer.isEmpty) return null;

    final idle = DateTime.now().difference(_lastOutputTime);
    if (idle < idleThreshold) return null;

    final question = _detect(_buffer);
    if (question != null) {
      _notified = true;
    }
    return question;
  }

  void reset() {
    _buffer = '';
    _notified = false;
  }

  static String _stripAnsi(String text) {
    return text.replaceAll(_ansiEscape, '');
  }

  static String? _detect(String rawText) {
    final text = _stripAnsi(rawText);
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) return null;

    final tail = lines.length > 15 ? lines.sublist(lines.length - 15) : lines;

    // Claude Code permission prompts: "Allow Read /path?"
    for (final line in tail.reversed) {
      if (RegExp(r'\bAllow\b.*\?', caseSensitive: false).hasMatch(line)) {
        return line;
      }
    }

    // AskUserQuestion: question line with ? followed by numbered options
    for (var i = 0; i < tail.length; i++) {
      final line = tail[i];
      if (line.endsWith('?')) {
        final remaining = tail.sublist(i + 1);
        final optionCount = remaining.where((r) {
          return RegExp(r'^(\d+[.)]\s|[-•●◉◯►▸]\s|>\s|\(\s*\)\s|\(\s*[xX•]\s*\)\s)')
              .hasMatch(r);
        }).length;
        if (optionCount >= 2) return line;
        if (i >= tail.length - 3) return line;
      }
    }

    // Generic question at the very end (last 3 lines)
    final lastLines = tail.length > 3 ? tail.sublist(tail.length - 3) : tail;
    for (final line in lastLines.reversed) {
      if (line.endsWith('?') && line.length > 10) {
        return line;
      }
    }

    // y/n prompts
    for (final line in lastLines.reversed) {
      if (RegExp(r'\(y/n\)|\(Y/n\)|\(y/N\)|\[y/N\]|\[Y/n\]', caseSensitive: false)
          .hasMatch(line)) {
        return line;
      }
    }

    return null;
  }
}
