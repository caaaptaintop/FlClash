import 'dart:async';
import 'dart:collection';

import 'package:fl_clash/common/node_quality.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod/riverpod.dart';

import 'app.dart';
import 'core.dart';
import 'route_state.dart';
import 'state.dart';

@immutable
class NodeQualityEntry {
  const NodeQualityEntry({
    this.report,
    this.loading = false,
    this.failed = false,
  });

  final NodeQualityReport? report;
  final bool loading;
  final bool failed;
}

final nodeQualityProvider =
    NotifierProvider<NodeQuality, Map<String, NodeQualityEntry>>(
      NodeQuality.new,
    );

class NodeQuality extends Notifier<Map<String, NodeQualityEntry>> {
  final _queue = Queue<_Job>();
  final _pending = <String, _Job>{};
  int _epoch = 0;
  int _active = 0;
  RouteState _route = const RouteState();
  int? _coreEpoch;
  Timer? _routeWaitTimer;

  bool get _routeReady => _route.synced && _route.live;

  @override
  Map<String, NodeQualityEntry> build() {
    _route = ref.read(routeTrackerProvider);
    _coreEpoch = _route.synced ? _route.coreEpoch : null;
    ref.listen(
      currentProfileProvider.select(
        (profile) => (profile?.id, profile?.lastUpdateDate),
      ),
      (_, _) {
        _cancel();
        state = const {};
      },
    );
    ref.listen(coreStatusProvider, (_, status) {
      if (status != CoreStatus.connected) {
        _failLoading();
      }
    });
    ref.listen(providersProvider, (previous, next) {
      if (!listEquals(previous, next)) {
        _cancel();
        state = const {};
      }
    });
    ref.listen(routeTrackerProvider, (previous, route) {
      _route = route;
      if ((previous?.synced == true && !route.synced) ||
          (previous?.live == true && !route.live)) {
        _failLoading();
      }
      if (!_routeReady) {
        return;
      }
      _cancelRouteWait();
      if (_coreEpoch != null && _coreEpoch != route.coreEpoch) {
        _cancel();
        state = const {};
      }
      _coreEpoch = route.coreEpoch;
      _drain();
    });
    final tracker = ref.read(routeTrackerProvider.notifier);
    var attached = false;
    var disposed = false;
    ref.onDispose(() {
      disposed = true;
      _cancel();
      if (attached) {
        scheduleMicrotask(() {
          if (tracker.ref.mounted) {
            tracker.detach();
          }
        });
      }
    });
    scheduleMicrotask(() {
      if (!disposed && ref.mounted) {
        attached = true;
        tracker.attach();
      }
    });
    return const {};
  }

  Future<void> refresh(Iterable<String> proxyNames) async {
    if (!ref.mounted) {
      return;
    }
    final profileId = ref.read(currentProfileProvider)?.id;
    final connected = ref.read(coreStatusProvider) == CoreStatus.connected;
    final waits = <Future<void>>[];
    final entries = {...state};
    for (final name in proxyNames.toSet()) {
      if (!isNodeQualityTarget(name)) {
        continue;
      }
      final existing = _pending[name];
      if (existing != null) {
        waits.add(existing.done.future);
        continue;
      }
      final previous = entries[name]?.report;
      if (profileId == null || !connected) {
        entries[name] = NodeQualityEntry(report: previous, failed: true);
        continue;
      }
      final job = _Job(name, profileId, _epoch);
      _pending[name] = job;
      _queue.add(job);
      entries[name] = NodeQualityEntry(report: previous, loading: true);
      waits.add(job.done.future);
    }
    state = Map.unmodifiable(entries);
    _drain();
    await Future.wait(waits);
  }

  void _cancel() {
    _cancelRouteWait();
    _epoch++;
    _queue.clear();
    for (final job in _pending.values) {
      if (!job.done.isCompleted) {
        job.done.complete();
      }
    }
    _pending.clear();
  }

  void _failLoading() {
    _cancel();
    state = Map.unmodifiable({
      for (final entry in state.entries)
        entry.key: NodeQualityEntry(
          report: entry.value.report,
          failed: entry.value.failed || entry.value.loading,
        ),
    });
  }

  void _cancelRouteWait() {
    _routeWaitTimer?.cancel();
    _routeWaitTimer = null;
  }

  void _waitForRoute() {
    _routeWaitTimer ??= Timer(const Duration(seconds: 8), () {
      _routeWaitTimer = null;
      if (!ref.mounted || _routeReady) {
        return;
      }
      final names = _pending.keys.toSet();
      _cancel();
      state = Map.unmodifiable({
        ...state,
        for (final name in names)
          name: NodeQualityEntry(report: state[name]?.report, failed: true),
      });
    });
  }

  bool _current(_Job job) =>
      ref.mounted &&
      _routeReady &&
      job.epoch == _epoch &&
      ref.read(currentProfileProvider)?.id == job.profileId &&
      ref.read(coreStatusProvider) == CoreStatus.connected;

  void _drain() {
    if (!ref.mounted) {
      return;
    }
    if (!_routeReady) {
      if (_queue.isNotEmpty) {
        _waitForRoute();
      }
      return;
    }
    while (_active < 2 && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _active++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_Job job) async {
    NodeQualityReport? report;
    try {
      if (_current(job)) {
        report = await lookupNodeQuality(
          ref.read(coreHandlerProvider),
          job.name,
        );
      }
    } catch (_) {
      report = null;
    } finally {
      if (_current(job)) {
        state = Map.unmodifiable({
          ...state,
          job.name: NodeQualityEntry(
            report: report ?? state[job.name]?.report,
            failed: report == null,
          ),
        });
      }
      if (identical(_pending[job.name], job)) {
        _pending.remove(job.name);
      }
      if (!job.done.isCompleted) {
        job.done.complete();
      }
      _active--;
      _drain();
    }
  }
}

class _Job {
  _Job(this.name, this.profileId, this.epoch);

  final String name;
  final int profileId;
  final int epoch;
  final done = Completer<void>();
}
