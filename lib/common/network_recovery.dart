import 'dart:async';

final class NetworkRecovery {
  final bool Function() isEnabled;
  final Future<bool> Function() recover;
  final Duration settleDuration;
  final Duration retryLimit;

  Timer? _timer;
  bool _running = false;
  bool _pending = false;
  bool _disposed = false;
  int _revision = 0;
  Duration _retryDelay = const Duration(seconds: 1);

  NetworkRecovery({
    required this.isEnabled,
    required this.recover,
    this.settleDuration = const Duration(seconds: 1),
    this.retryLimit = const Duration(seconds: 30),
  });

  void request() {
    if (_disposed || !isEnabled()) return;
    _revision++;
    _pending = true;
    _retryDelay = const Duration(seconds: 1);
    _schedule(settleDuration);
  }

  void cancel() {
    _revision++;
    _pending = false;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (_running || !_pending || _disposed) return;
    _timer = Timer(delay, () => unawaited(_run()));
  }

  Future<void> _run() async {
    _timer = null;
    if (_disposed || !_pending || !isEnabled()) {
      cancel();
      return;
    }
    final revision = _revision;
    _running = true;
    _pending = false;
    var recovered = false;
    try {
      recovered = await recover();
    } catch (_) {
      recovered = false;
    } finally {
      _running = false;
      if (!_disposed && isEnabled()) {
        if (revision != _revision) {
          _schedule(settleDuration);
        } else if (!recovered) {
          _pending = true;
          _schedule(_retryDelay);
          final nextDelay = _retryDelay * 2;
          _retryDelay = nextDelay > retryLimit ? retryLimit : nextDelay;
        }
      }
    }
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
