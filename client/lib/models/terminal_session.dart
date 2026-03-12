class TerminalSessionInfo {
  final String id;
  final String shell;
  final double createdAt;
  final int cols;
  final int rows;
  final String title;
  final bool alive;

  const TerminalSessionInfo({
    required this.id,
    required this.shell,
    required this.createdAt,
    required this.cols,
    required this.rows,
    required this.title,
    required this.alive,
  });

  factory TerminalSessionInfo.fromJson(Map<String, dynamic> json) =>
      TerminalSessionInfo(
        id: json['id'] as String,
        shell: json['shell'] as String,
        createdAt: (json['created_at'] as num).toDouble(),
        cols: json['cols'] as int,
        rows: json['rows'] as int,
        title: json['title'] as String,
        alive: json['alive'] as bool,
      );
}
