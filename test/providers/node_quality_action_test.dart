import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/node_quality.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const ProbeParams(url: '', timeout: 0)));

  test(
    'latency completion does not wait for quality or change the selection',
    () async {
      final core = _Core();
      final quality = Completer<ProbeResult?>();
      const url = 'https://example.com/generate_204';
      when(() => core.probe(any())).thenAnswer((_) => quality.future);
      when(() => core.asyncTestDelay(url, 'node')).thenAnswer(
        (_) async => const Delay(name: 'node', url: url, value: 128),
      );
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(
            () => TestProfiles([
              const Profile(
                id: 1,
                autoUpdateDuration: Duration.zero,
                selectedMap: {'Proxy': 'existing'},
              ),
            ]),
          ),
          currentProfileIdProvider.overrideWithBuild((_, _) => 1),
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          routeTrackerProvider.overrideWithBuild(
            (_, _) => const RouteState(coreEpoch: 1, synced: true, live: true),
          ),
        ],
      );
      addTearDown(container.dispose);
      final selection = container.read(currentProfileProvider)?.selectedMap;
      final mode = container.read(patchClashConfigProvider).mode;

      await container
          .read(proxiesActionProvider.notifier)
          .proxyDelayTest(const Proxy(name: 'node', type: 'Shadowsocks'), url);

      expect(quality.isCompleted, isFalse);
      expect(container.read(delayDataSourceProvider)[url]?['node'], 128);
      expect(container.read(nodeQualityProvider)['node']?.loading, isTrue);
      final params =
          verify(() => core.probe(captureAny())).captured.single as ProbeParams;
      expect(params.proxyName, 'node');
      expect(container.read(currentProfileProvider)?.selectedMap, selection);
      expect(container.read(patchClashConfigProvider).mode, mode);
      verify(() => core.asyncTestDelay(url, 'node')).called(1);
      verifyNoMoreInteractions(core);
      quality.complete(
        const ProbeResult(
          statusCode: 200,
          body: '{"ip":"203.0.113.1","fraudScore":48}',
        ),
      );
      await pumpEventQueue();
      expect(
        container.read(nodeQualityProvider)['node']?.report?.riskScore,
        48,
      );
    },
  );
}
