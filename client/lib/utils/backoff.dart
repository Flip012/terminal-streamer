import 'dart:math';

final _random = Random();

/// Returns an exponential backoff duration with jitter.
///
/// Calculates `base * 2^attempt`, capped at [max], plus 0-25% random jitter.
Duration backoffDelay({
  required int attempt,
  Duration base = const Duration(seconds: 1),
  Duration max = const Duration(seconds: 30),
}) {
  final baseMs = base.inMilliseconds * pow(2, attempt);
  final cappedMs = min(baseMs.toInt(), max.inMilliseconds);
  final jitter = (cappedMs * 0.25 * _random.nextDouble()).toInt();
  return Duration(milliseconds: cappedMs + jitter);
}
