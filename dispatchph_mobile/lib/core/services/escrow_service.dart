import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

const _debugAutoReleaseSeconds = 30;
const _prodAutoReleaseHours = 24;

enum EscrowEvent {
  pay,
  markShipped,
  markDelivered,
  confirmDelivery,
  requestRefund,
  autoRelease,
}

class EscrowService {
  final _uuid = const Uuid();
  final Map<String, Timer> _timers = {};
  final Map<String, DateTime> _deadlines = {};

  bool get _isDebug => kDebugMode;

  Duration get autoReleaseDuration =>
      _isDebug
          ? Duration(seconds: _debugAutoReleaseSeconds)
          : Duration(hours: _prodAutoReleaseHours);

  String generateId() => _uuid.v4();

  String generateChatId() => _uuid.v4();

  String generateMessageId() => _uuid.v4();

  DateTime calculateAutoReleaseAt() => DateTime.now().add(autoReleaseDuration);

  Duration getRemainingTime(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String formatRemainingTime(Duration d) {
    if (d.isNegative || d == Duration.zero) return 'Auto-releasing now...';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (_isDebug) {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${hours}h ${minutes}m ${seconds}s';
  }

  void scheduleAutoRelease({
    required String orderId,
    required DateTime deadline,
    required VoidCallback onRelease,
  }) {
    cancelAutoRelease(orderId);
    final duration = deadline.difference(DateTime.now());
    if (duration.isNegative) {
      onRelease();
      return;
    }
    _deadlines[orderId] = deadline;
    _timers[orderId] = Timer(duration, onRelease);
  }

  void cancelAutoRelease(String orderId) {
    _timers[orderId]?.cancel();
    _timers.remove(orderId);
    _deadlines.remove(orderId);
  }

  Stream<DateTime> watchTimer(String orderId) {
    final deadline = _deadlines[orderId];
    if (deadline == null) return const Stream.empty();

    return Stream.periodic(
      const Duration(seconds: 1),
      (_) => deadline,
    ).takeWhile((_) => _timers.containsKey(orderId));
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _deadlines.clear();
  }
}
