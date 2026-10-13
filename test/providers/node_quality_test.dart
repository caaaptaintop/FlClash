import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/node_quality.dart';
import 'package:fl_clash/providers/route_state.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

class _UnsyncRouteTracker extends RouteTracker {
  void loseSync() {
    state = state.copyWith(synced: false);
  }
}

ProbeResult _answer(String ip) => ProbeResult(
  statusCode: 200,
  body: jsonEncode({'ip': ip, 'fraudScore': 48}),
);

void main() {
  setUpAll(() => registerFallbackValue(const ProbeParams(url: '', timeout: 0)));

  late _MockCore core;
  late List<ProbeParams> calls;
  late List<Completer<ProbeResult?>> replies;
  late Profile? profile;

  setUp(() {
    core = _MockCore();
    calls = [];
    replies = [];
    profile = const Profile(id: 1, autoUpdateDuration: Duration.zero);
    when(() => core.probe(any())).thenAnswer((invocation) {
      calls.add(invocation.positionalArguments.single as ProbeParams);
      final reply = Completer<ProbeResult?>();
      replies.add(reply);
      return reply.future;
    });
  });

  ProviderContainer build({
    bool disposeAtEnd = true,
    bool realRouteTracker = false,
    bool allowSyncLoss = false,
  }) {
    final container = ProviderContainer(
      overrides: [
        currentProfileProvider.overrideWith((_) => profile),
        coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
        providersProvider.overrideWithBuild((_, _) => []),
        if (realRouteTracker) ...[
          if (allowSyncLoss)
            routeTrackerProvider.overrideWith(_UnsyncRouteTracker.new),
          initProvider.overrideWithBuild((_, _) => true),
          appVisibleProvider.overrideWithBuild((_, _) => true),
          runTimeProvider.overrideWithBuild((_, _) => 1),
          suspendProvider.overrideWithValue(false),
        ] else
          routeTrackerProvider.overrideWithBuild(
            (_, _) => const RouteState(coreEpoch: 1, synced: true, live: true),
          ),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    if (disposeAtEnd) {
      addTearDown(container.dispose);
    }
    container.read(nodeQualityProvider);
    return container;
  }

  void switchProfile(ProviderContainer container, int id) {
    profile = Profile(id: id, autoUpdateDuration: Duration.zero);
    container.invalidate(currentProfileProvider);
    container.read(currentProfileProvider);
  }

  test(
    'at most two nodes run and queued nodes keep loading until settled',
    () async {
      final container = build();
      final run = container.read(nodeQualityProvider.notifier).refresh([
        'A',
        'B',
        'C',
      ]);

      expect(calls.map((call) => call.proxyName), ['A', 'B']);
      expect(container.read(nodeQualityProvider)['C']?.loading, isTrue);
      replies[0].complete(_answer('203.0.113.1'));
      await pumpEventQueue();
      expect(calls.map((call) => call.proxyName), ['A', 'B', 'C']);
      expect(container.read(nodeQualityProvider)['A']?.loading, isFalse);
      expect(container.read(nodeQualityProvider)['C']?.loading, isTrue);
      replies[1].complete(_answer('203.0.113.2'));
      replies[2].complete(_answer('203.0.113.3'));
      await run;
      expect(
        container.read(nodeQualityProvider).values.every((e) => !e.loading),
        isTrue,
      );
    },
  );

  test('duplicate queued and active nodes share the pending request', () async {
    final container = build();
    final notifier = container.read(nodeQualityProvider.notifier);
    final first = notifier.refresh(['A', 'A', 'B', 'C']);
    final second = notifier.refresh(['A', 'C']);
    expect(calls.length, 2);
    replies[0].complete(_answer('203.0.113.1'));
    await pumpEventQueue();
    expect(calls.length, 3);
    replies[1].complete(_answer('203.0.113.2'));
    replies[2].complete(_answer('203.0.113.3'));
    await Future.wait([first, second]);
    expect(calls.map((call) => call.proxyName), ['A', 'B', 'C']);
  });

  test(
    'a later refresh fetches a new exit and clears a previous failure',
    () async {
      final container = build();
      final notifier = container.read(nodeQualityProvider.notifier);
      final first = notifier.refresh(['A']);
      replies[0].complete(_answer('203.0.113.1'));
      await first;
      final old = container.read(nodeQualityProvider)['A']!.report!;

      final failed = notifier.refresh(['A']);
      expect(container.read(nodeQualityProvider)['A']?.loading, isTrue);
      replies[1].completeError(StateError('probe failed'));
      await failed;
      final stale = container.read(nodeQualityProvider)['A']!;
      expect(stale.report, same(old));
      expect(stale.report?.checkedAt, old.checkedAt);
      expect(stale.failed, isTrue);
      expect(stale.loading, isFalse);

      final retry = notifier.refresh(['A']);
      expect(container.read(nodeQualityProvider)['A']?.failed, isFalse);
      replies[2].complete(_answer('203.0.113.2'));
      await retry;
      final fresh = container.read(nodeQualityProvider)['A']!;
      expect(fresh.report?.ip, '203.0.113.2');
      expect(fresh.report, isNot(same(old)));
      expect(fresh.report!.checkedAt.isBefore(old.checkedAt), isFalse);
      expect(fresh.failed, isFalse);
      expect(fresh.loading, isFalse);
      expect(calls.length, 3);
    },
  );

  test(
    'an invalid response marks a first attempt failed without a report',
    () async {
      final container = build();
      final run = container.read(nodeQualityProvider.notifier).refresh(['A']);
      replies[0].complete(_answer('invalid'));
      await run;
      final entry = container.read(nodeQualityProvider)['A']!;
      expect(entry.report, isNull);
      expect(entry.failed, isTrue);
      expect(entry.loading, isFalse);
    },
  );

  test(
    'profile switches cancel the queue and discard late same-name results',
    () async {
      final container = build();
      final notifier = container.read(nodeQualityProvider.notifier);
      final oldRun = notifier.refresh(['A', 'B', 'C']);
      switchProfile(container, 2);
      await oldRun;
      expect(container.read(nodeQualityProvider), isEmpty);

      final newRun = notifier.refresh(['A']);
      expect(calls.length, 2);
      replies[1].complete(_answer('203.0.113.2'));
      await pumpEventQueue();
      expect(calls.map((call) => call.proxyName), ['A', 'B', 'A']);
      replies[2].complete(_answer('203.0.113.3'));
      await newRun;
      replies[0].complete(_answer('203.0.113.1'));
      await pumpEventQueue();
      expect(
        container.read(nodeQualityProvider)['A']?.report?.ip,
        '203.0.113.3',
      );
      expect(container.read(nodeQualityProvider).containsKey('C'), isFalse);
    },
  );

  test('switching away and back still discards the original epoch', () async {
    final container = build();
    final notifier = container.read(nodeQualityProvider.notifier);
    final oldRun = notifier.refresh(['A']);
    switchProfile(container, 2);
    switchProfile(container, 1);
    await oldRun;
    final newRun = notifier.refresh(['A']);
    replies[1].complete(_answer('203.0.113.2'));
    await newRun;
    replies[0].complete(_answer('203.0.113.1'));
    await pumpEventQueue();
    expect(container.read(nodeQualityProvider)['A']?.report?.ip, '203.0.113.2');
  });

  test('a reload of the same profile also discards pending results', () async {
    final container = build();
    final run = container.read(nodeQualityProvider.notifier).refresh(['A']);
    profile = profile!.copyWith(lastUpdateDate: DateTime.utc(2026, 10, 13));
    container.invalidate(currentProfileProvider);
    container.read(currentProfileProvider);
    await run;
    replies[0].complete(_answer('203.0.113.1'));
    await pumpEventQueue();
    expect(container.read(nodeQualityProvider), isEmpty);
  });

  test('a node supplier refresh clears reports and cancels old work', () async {
    final container = build();
    final supplier = ExternalProvider(
      name: 'subscription',
      type: 'Proxy',
      count: 3,
      vehicleType: 'HTTP',
      updateAt: DateTime.utc(2026, 10, 12),
    );
    container.read(providersProvider.notifier).value = [supplier];
    final notifier = container.read(nodeQualityProvider.notifier);
    final first = notifier.refresh(['A']);
    replies[0].complete(_answer('203.0.113.1'));
    await first;
    final oldRun = notifier.refresh(['A', 'B', 'C']);
    container.read(providersProvider.notifier).value = [
      supplier.copyWith(updateAt: DateTime.utc(2026, 10, 13)),
    ];
    await oldRun;
    expect(container.read(nodeQualityProvider), isEmpty);

    final newRun = notifier.refresh(['A']);
    expect(calls.length, 3);
    replies[2].complete(_answer('203.0.113.2'));
    await pumpEventQueue();
    expect(calls.map((call) => call.proxyName), ['A', 'A', 'B', 'A']);
    replies[3].complete(_answer('203.0.113.3'));
    await newRun;
    replies[1].complete(_answer('203.0.113.1'));
    await pumpEventQueue();
    expect(container.read(nodeQualityProvider)['A']?.report?.ip, '203.0.113.3');
    expect(container.read(nodeQualityProvider).containsKey('C'), isFalse);
  });

  test('unchanged supplier metadata does not cancel a probe', () async {
    final container = build();
    final supplier = ExternalProvider(
      name: 'subscription',
      type: 'Proxy',
      count: 1,
      vehicleType: 'HTTP',
      updateAt: DateTime.utc(2026, 10, 13),
    );
    container.read(providersProvider.notifier).value = [supplier];
    final run = container.read(nodeQualityProvider.notifier).refresh(['A']);
    container.read(providersProvider.notifier).value = [supplier.copyWith()];
    expect(container.read(nodeQualityProvider)['A']?.loading, isTrue);
    replies[0].complete(_answer('203.0.113.1'));
    await run;
    expect(container.read(nodeQualityProvider)['A']?.report?.ip, '203.0.113.1');
  });

  test('a structural core epoch change cancels same-profile results', () async {
    final container = build();
    final run = container.read(nodeQualityProvider.notifier).refresh(['A']);
    container
        .read(routeTrackerProvider.notifier)
        .applySnapshot(const RouteSnapshot(coreEpoch: 2));
    await run;
    replies[0].complete(_answer('203.0.113.1'));
    await pumpEventQueue();
    expect(container.read(nodeQualityProvider), isEmpty);
  });

  test(
    'owns the real route subscription and waits for its first snapshot',
    () async {
      final snapshot = Completer<RouteSnapshot?>();
      when(() => core.watchRoute(true)).thenAnswer((_) => snapshot.future);
      when(() => core.watchRoute(false)).thenAnswer((_) async => null);
      final container = build(realRouteTracker: true);
      final run = container.read(nodeQualityProvider.notifier).refresh(['A']);
      expect(calls, isEmpty);
      expect(container.read(nodeQualityProvider)['A']?.loading, isTrue);
      await pumpEventQueue();
      verify(() => core.watchRoute(true)).called(1);
      expect(calls, isEmpty);

      snapshot.complete(const RouteSnapshot(coreEpoch: 7));
      await pumpEventQueue();
      expect(calls.map((call) => call.proxyName), ['A']);
      replies[0].complete(_answer('203.0.113.1'));
      await run;
      expect(
        container.read(nodeQualityProvider)['A']?.report?.ip,
        '203.0.113.1',
      );
      expect(container.read(nodeQualityProvider)['A']?.failed, isFalse);

      container.invalidate(nodeQualityProvider);
      await pumpEventQueue();
      verify(() => core.watchRoute(false)).called(1);
      verifyNever(() => core.watchRoute(true));
    },
  );

  test('releases only its own real route subscription lease', () async {
    when(
      () => core.watchRoute(true),
    ).thenAnswer((_) async => const RouteSnapshot(coreEpoch: 7));
    when(() => core.watchRoute(false)).thenAnswer((_) async => null);
    final container = build(realRouteTracker: true);
    await pumpEventQueue();
    verify(() => core.watchRoute(true)).called(1);
    final otherObserver = container.read(routeTrackerProvider.notifier);
    otherObserver.attach();

    container.invalidate(nodeQualityProvider);
    await pumpEventQueue();
    verifyNever(() => core.watchRoute(false));
    otherObserver.detach();
    await pumpEventQueue();
    verify(() => core.watchRoute(false)).called(1);
  });

  test(
    'real route resync invalidates reports and rejects late structural results',
    () async {
      var snapshot = const RouteSnapshot(coreEpoch: 7);
      when(() => core.watchRoute(true)).thenAnswer((_) async => snapshot);
      when(() => core.watchRoute(false)).thenAnswer((_) async => null);
      final container = build(realRouteTracker: true);
      final notifier = container.read(nodeQualityProvider.notifier);
      final first = notifier.refresh(['A']);
      await pumpEventQueue();
      verify(() => core.watchRoute(true)).called(1);
      replies[0].complete(_answer('203.0.113.1'));
      await first;
      final oldRun = notifier.refresh(['A', 'B', 'C']);

      snapshot = const RouteSnapshot(coreEpoch: 8);
      container.read(routeTrackerProvider.notifier).resync();
      await pumpEventQueue();
      verify(() => core.watchRoute(true)).called(1);
      await oldRun;
      expect(container.read(nodeQualityProvider), isEmpty);
      final newRun = notifier.refresh(['A']);
      expect(calls.length, 3);
      replies[2].complete(_answer('203.0.113.2'));
      await pumpEventQueue();
      expect(calls.map((call) => call.proxyName), ['A', 'A', 'B', 'A']);
      replies[3].complete(_answer('203.0.113.3'));
      await newRun;
      replies[1].complete(_answer('203.0.113.1'));
      await pumpEventQueue();
      expect(
        container.read(nodeQualityProvider)['A']?.report?.ip,
        '203.0.113.3',
      );
      expect(container.read(nodeQualityProvider).containsKey('C'), isFalse);
    },
  );

  test(
    'disposal before the deferred attach never opens a subscription',
    () async {
      when(
        () => core.watchRoute(true),
      ).thenAnswer((_) async => const RouteSnapshot(coreEpoch: 7));
      when(() => core.watchRoute(false)).thenAnswer((_) async => null);
      final container = build(realRouteTracker: true, disposeAtEnd: false);
      final run = container.read(nodeQualityProvider.notifier).refresh(['A']);
      container.dispose();
      await run;
      await pumpEventQueue();
      verifyNever(() => core.watchRoute(any()));
      expect(calls, isEmpty);
    },
  );

  test(
    'hiding the real route settles loading and rejects answers after resume',
    () async {
      when(
        () => core.watchRoute(true),
      ).thenAnswer((_) async => const RouteSnapshot(coreEpoch: 7));
      when(() => core.watchRoute(false)).thenAnswer((_) async => null);
      final container = build(realRouteTracker: true);
      final notifier = container.read(nodeQualityProvider.notifier);
      final first = notifier.refresh(['A']);
      await pumpEventQueue();
      replies[0].complete(_answer('203.0.113.1'));
      await first;
      final previous = container.read(nodeQualityProvider)['A']!.report;

      final retry = notifier.refresh(['A', 'B', 'C']);
      container.read(appVisibleProvider.notifier).value = false;
      await pumpEventQueue();
      await retry;
      expect(container.read(routeTrackerProvider).synced, isTrue);
      expect(container.read(routeTrackerProvider).live, isFalse);
      expect(
        container
            .read(nodeQualityProvider)
            .values
            .every((entry) => !entry.loading && entry.failed),
        isTrue,
      );
      expect(container.read(nodeQualityProvider)['A']?.report, same(previous));
      replies[1].complete(_answer('203.0.113.2'));
      await pumpEventQueue();
      expect(container.read(nodeQualityProvider)['A']?.report, same(previous));

      container.read(appVisibleProvider.notifier).value = true;
      await pumpEventQueue();
      expect(container.read(routeTrackerProvider).coreEpoch, 7);
      expect(container.read(routeTrackerProvider).live, isTrue);
      expect(container.read(nodeQualityProvider)['A']?.loading, isFalse);
      final resumed = notifier.refresh(['A']);
      replies[3].complete(_answer('203.0.113.3'));
      await resumed;
      replies[2].complete(_answer('203.0.113.2'));
      await pumpEventQueue();
      expect(
        container.read(nodeQualityProvider)['A']?.report?.ip,
        '203.0.113.3',
      );
      expect(container.read(nodeQualityProvider)['C']?.loading, isFalse);
      expect(container.read(nodeQualityProvider)['C']?.report, isNull);
      expect(calls.map((call) => call.proxyName), ['A', 'A', 'B', 'A']);
    },
  );

  test('losing sync without disconnect settles a lone active entry', () async {
    when(
      () => core.watchRoute(true),
    ).thenAnswer((_) async => const RouteSnapshot(coreEpoch: 7));
    when(() => core.watchRoute(false)).thenAnswer((_) async => null);
    final container = build(realRouteTracker: true, allowSyncLoss: true);
    final notifier = container.read(nodeQualityProvider.notifier);
    final first = notifier.refresh(['A']);
    await pumpEventQueue();
    replies[0].complete(_answer('203.0.113.1'));
    await first;
    final previous = container.read(nodeQualityProvider)['A']!.report;
    final retry = notifier.refresh(['A']);

    final tracker =
        container.read(routeTrackerProvider.notifier) as _UnsyncRouteTracker;
    tracker.loseSync();
    await retry;
    expect(container.read(coreStatusProvider), CoreStatus.connected);
    expect(container.read(nodeQualityProvider)['A']?.loading, isFalse);
    expect(container.read(nodeQualityProvider)['A']?.failed, isTrue);
    expect(container.read(nodeQualityProvider)['A']?.report, same(previous));
    replies[1].complete(_answer('203.0.113.2'));
    await pumpEventQueue();

    tracker.resync();
    await pumpEventQueue();
    expect(container.read(routeTrackerProvider).synced, isTrue);
    expect(container.read(routeTrackerProvider).coreEpoch, 7);
    expect(container.read(nodeQualityProvider)['A']?.loading, isFalse);
    expect(container.read(nodeQualityProvider)['A']?.report, same(previous));
    final resumed = notifier.refresh(['A']);
    replies[2].complete(_answer('203.0.113.3'));
    await resumed;
    expect(container.read(nodeQualityProvider)['A']?.failed, isFalse);
  });

  testWidgets('a never-returning initial route snapshot has a bounded wait', (
    tester,
  ) async {
    final snapshot = Completer<RouteSnapshot?>();
    when(() => core.watchRoute(true)).thenAnswer((_) => snapshot.future);
    when(() => core.watchRoute(false)).thenAnswer((_) async => null);
    final container = build(realRouteTracker: true);
    final run = container.read(nodeQualityProvider.notifier).refresh([
      'A',
      'B',
    ]);
    await tester.pump();
    expect(container.read(nodeQualityProvider)['A']?.loading, isTrue);
    await tester.pump(const Duration(seconds: 8));
    await run;
    expect(
      container
          .read(nodeQualityProvider)
          .values
          .every(
            (entry) => !entry.loading && entry.failed && entry.report == null,
          ),
      isTrue,
    );
    expect(calls, isEmpty);

    snapshot.complete(const RouteSnapshot(coreEpoch: 7));
    await tester.pump();
    expect(calls, isEmpty);
    expect(container.read(nodeQualityProvider)['A']?.failed, isTrue);
    container.invalidate(nodeQualityProvider);
    await tester.pump();
  });

  testWidgets(
    'repeated initial route failures do not restart the wait budget',
    (tester) async {
      when(() => core.watchRoute(true)).thenAnswer((_) async => null);
      when(() => core.watchRoute(false)).thenAnswer((_) async => null);
      final container = build(realRouteTracker: true);
      final run = container.read(nodeQualityProvider.notifier).refresh(['A']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 5));
      await run;
      expect(container.read(nodeQualityProvider)['A']?.loading, isFalse);
      expect(container.read(nodeQualityProvider)['A']?.failed, isTrue);
      expect(calls, isEmpty);
      expect(
        verify(() => core.watchRoute(captureAny())).captured.length,
        greaterThan(1),
      );
      container.invalidate(nodeQualityProvider);
      await tester.pump();
    },
  );

  testWidgets('a synced batch may remain queued beyond the route wait budget', (
    tester,
  ) async {
    when(
      () => core.watchRoute(true),
    ).thenAnswer((_) async => const RouteSnapshot(coreEpoch: 7));
    when(() => core.watchRoute(false)).thenAnswer((_) async => null);
    final container = build(realRouteTracker: true, disposeAtEnd: false);
    final run = container.read(nodeQualityProvider.notifier).refresh([
      'A',
      'B',
      'C',
    ]);
    await tester.pump();
    expect(calls.length, 2);
    await tester.pump(const Duration(seconds: 9));
    expect(container.read(nodeQualityProvider)['C']?.loading, isTrue);
    expect(container.read(nodeQualityProvider)['C']?.failed, isFalse);
    replies[0].complete(_answer('203.0.113.1'));
    await tester.pump();
    expect(calls.length, 3);
    replies[1].complete(_answer('203.0.113.2'));
    replies[2].complete(_answer('203.0.113.3'));
    await tester.pump();
    await run;
    expect(container.read(nodeQualityProvider)['C']?.failed, isFalse);
    container.dispose();
    await tester.pump();
  });

  testWidgets('disposal cancels the initial route wait timer and queue', (
    tester,
  ) async {
    final snapshot = Completer<RouteSnapshot?>();
    when(() => core.watchRoute(true)).thenAnswer((_) => snapshot.future);
    when(() => core.watchRoute(false)).thenAnswer((_) async => null);
    final container = build(realRouteTracker: true, disposeAtEnd: false);
    final run = container.read(nodeQualityProvider.notifier).refresh(['A']);
    await tester.pump();
    verify(() => core.watchRoute(true)).called(1);
    container.dispose();
    await run;
    snapshot.complete(const RouteSnapshot(coreEpoch: 7));
    await tester.pump();
    verifyNever(() => core.watchRoute(false));
    expect(calls, isEmpty);
  });

  testWidgets('disposal discards active answers and clears queued work', (
    tester,
  ) async {
    when(
      () => core.watchRoute(true),
    ).thenAnswer((_) async => const RouteSnapshot(coreEpoch: 7));
    when(() => core.watchRoute(false)).thenAnswer((_) async => null);
    final container = build(realRouteTracker: true, disposeAtEnd: false);
    final run = container.read(nodeQualityProvider.notifier).refresh([
      'A',
      'B',
      'C',
    ]);
    await tester.pump();
    expect(calls.length, 2);
    container.dispose();
    await run;
    replies[0].complete(_answer('203.0.113.1'));
    replies[1].complete(_answer('203.0.113.2'));
    await tester.pump();
    expect(calls.length, 2);
    verifyNever(() => core.watchRoute(false));
  });

  test('probing leaves the selected node and mode intact', () async {
    profile = profile!.copyWith(selectedMap: {'Proxy': 'Daily'});
    final container = build();
    container.listen(patchClashConfigProvider, (_, _) {});
    container.read(patchClashConfigProvider.notifier).value =
        const PatchClashConfig(mode: Mode.global);
    final run = container.read(nodeQualityProvider.notifier).refresh(['A']);
    replies[0].complete(_answer('203.0.113.1'));
    await run;

    expect(container.read(currentProfileProvider)?.selectedMap, {
      'Proxy': 'Daily',
    });
    expect(container.read(patchClashConfigProvider).mode, Mode.global);
    final asked =
        verify(() => core.probe(captureAny())).captured.single as ProbeParams;
    expect(asked.proxyName, 'A');
    verifyNoMoreInteractions(core);
  });

  test(
    'core disconnect preserves the last report and ends its retry',
    () async {
      final container = build();
      final notifier = container.read(nodeQualityProvider.notifier);
      final first = notifier.refresh(['A']);
      replies[0].complete(_answer('203.0.113.1'));
      await first;
      final old = container.read(nodeQualityProvider)['A']!.report;
      final retry = notifier.refresh(['A']);
      container.read(coreStatusProvider.notifier).value =
          CoreStatus.disconnected;
      await retry;
      final entry = container.read(nodeQualityProvider)['A']!;
      expect(entry.report, same(old));
      expect(entry.loading, isFalse);
      expect(entry.failed, isTrue);
      replies[1].complete(_answer('203.0.113.2'));
      await pumpEventQueue();
      expect(container.read(nodeQualityProvider)['A']?.report, same(old));
    },
  );

  test(
    'core disconnect cancels pending work and rejects its late results',
    () async {
      final container = build();
      final notifier = container.read(nodeQualityProvider.notifier);
      final oldRun = notifier.refresh(['A', 'B', 'C']);
      container.read(coreStatusProvider.notifier).value =
          CoreStatus.disconnected;
      await oldRun;
      expect(
        container
            .read(nodeQualityProvider)
            .values
            .every((e) => !e.loading && e.failed),
        isTrue,
      );
      await notifier.refresh(['D']);
      expect(calls.length, 2);

      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      final newRun = notifier.refresh(['A']);
      replies[1].complete(_answer('203.0.113.2'));
      await pumpEventQueue();
      expect(calls.length, 3);
      replies[2].complete(_answer('203.0.113.3'));
      await newRun;
      replies[0].complete(_answer('203.0.113.1'));
      await pumpEventQueue();
      expect(
        container.read(nodeQualityProvider)['A']?.report?.ip,
        '203.0.113.3',
      );
      expect(container.read(nodeQualityProvider)['C']?.report, isNull);
    },
  );

  test(
    'disposal settles refresh callers and never starts queued nodes',
    () async {
      final container = build(disposeAtEnd: false);
      final run = container.read(nodeQualityProvider.notifier).refresh([
        'A',
        'B',
        'C',
      ]);
      container.dispose();
      await run;
      replies[0].complete(_answer('203.0.113.1'));
      replies[1].complete(_answer('203.0.113.2'));
      await pumpEventQueue();
      expect(calls.length, 2);
    },
  );

  test(
    'no selected profile and blank names cannot trigger routed probes',
    () async {
      profile = null;
      final container = build();
      await container.read(nodeQualityProvider.notifier).refresh([
        ' ',
        '',
        'A',
      ]);
      expect(calls, isEmpty);
      expect(container.read(nodeQualityProvider).keys, ['A']);
      expect(container.read(nodeQualityProvider)['A']?.failed, isTrue);
    },
  );

  test(
    'refresh skips built-in outbounds without creating quality state',
    () async {
      final container = build();
      await container.read(nodeQualityProvider.notifier).refresh([
        'DIRECT',
        'REJECT',
        'REJECT-DROP',
        'PASS',
        'COMPATIBLE',
        '',
        ' \t ',
      ]);
      expect(container.read(nodeQualityProvider), isEmpty);
      expect(calls, isEmpty);
      verifyNever(() => core.probe(any()));
    },
  );
}
