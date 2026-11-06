import 'dart:async';

import 'package:fl_clash/common/network_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('coalesces a burst of recovery requests', (tester) async {
    var calls = 0;
    final recovery = NetworkRecovery(
      isEnabled: () => true,
      recover: () async {
        calls++;
        return true;
      },
    );
    addTearDown(recovery.dispose);

    recovery.request();
    await tester.pump(const Duration(milliseconds: 700));
    recovery.request();
    await tester.pump(const Duration(milliseconds: 700));
    expect(calls, 0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 1);
  });

  testWidgets('retries failures with capped exponential backoff', (
    tester,
  ) async {
    var calls = 0;
    final recovery = NetworkRecovery(
      isEnabled: () => true,
      retryLimit: const Duration(seconds: 4),
      recover: () async => ++calls >= 5,
    );
    addTearDown(recovery.dispose);

    recovery.request();
    for (final seconds in [1, 1, 2, 4, 4]) {
      await tester.pump(Duration(seconds: seconds));
    }
    expect(calls, 5);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 5);
  });

  testWidgets('a thrown recovery is retried', (tester) async {
    var calls = 0;
    final recovery = NetworkRecovery(
      isEnabled: () => true,
      recover: () async {
        if (++calls == 1) throw StateError('network not ready');
        return true;
      },
    );
    addTearDown(recovery.dispose);

    recovery.request();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new network during recovery gets one serial follow-up', (
    tester,
  ) async {
    final first = Completer<bool>();
    var calls = 0;
    final recovery = NetworkRecovery(
      isEnabled: () => true,
      recover: () {
        calls++;
        return calls == 1 ? first.future : Future.value(true);
      },
    );
    addTearDown(recovery.dispose);

    recovery.request();
    await tester.pump(const Duration(seconds: 1));
    recovery.request();
    recovery.request();
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 1);
    first.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
  });

  testWidgets('manual stop cancels pending work and an in-flight retry', (
    tester,
  ) async {
    var enabled = true;
    var calls = 0;
    final first = Completer<bool>();
    final recovery = NetworkRecovery(
      isEnabled: () => enabled,
      recover: () {
        calls++;
        return first.future;
      },
    );
    addTearDown(recovery.dispose);

    recovery.request();
    recovery.cancel();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 0);
    recovery.request();
    await tester.pump(const Duration(seconds: 1));
    enabled = false;
    recovery.cancel();
    first.complete(false);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 1);
  });

  testWidgets('disabled and disposed recovery never starts work', (
    tester,
  ) async {
    var enabled = false;
    var calls = 0;
    final recovery = NetworkRecovery(
      isEnabled: () => enabled,
      recover: () async {
        calls++;
        return false;
      },
    );

    recovery.request();
    await tester.pump(const Duration(seconds: 1));
    enabled = true;
    recovery.request();
    recovery.dispose();
    recovery.request();
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 0);
  });
}
