class ServerConfig {
  final String host;
  final int port;
  final String apiKey;
  final bool useTls;

  const ServerConfig({
    required this.host,
    required this.port,
    required this.apiKey,
    this.useTls = false,
  });

  String get httpBaseUrl =>
      '${useTls ? 'https' : 'http'}://$host:$port';

  String get wsBaseUrl =>
      '${useTls ? 'wss' : 'ws'}://$host:$port';

  Map<String, String> get headers => {'X-API-Key': apiKey};

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'apiKey': apiKey,
        'useTls': useTls,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        host: json['host'] as String,
        port: json['port'] as int,
        apiKey: json['apiKey'] as String,
        useTls: json['useTls'] as bool? ?? false,
      );
}
