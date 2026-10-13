import 'package:fl_clash/common/node_quality.dart';
import 'package:fl_clash/providers/node_quality.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/proxies/quality.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _Quality extends NodeQuality {
  static NodeQualityEntry? entry;

  @override
  Map<String, NodeQualityEntry> build() => {'node': ?entry};
}

void main() {
  Future<void> pump(WidgetTester tester, NodeQualityEntry? entry) async {
    _Quality.entry = entry;
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          nodeQualityProvider.overrideWith(_Quality.new),
          profilesProvider.overrideWith(TestProfiles.new),
        ],
        child: const TestApp(
          locale: Locale('zh', 'CN'),
          child: NodeQualitySummary(proxyName: 'node'),
        ),
      ),
    );
    await tester.pump();
  }

  NodeQualityReport report({bool? residential, bool? native}) =>
      NodeQualityReport(
        ip: '203.0.113.1',
        checkedAt: DateTime(2026, 10, 13),
        riskScore: 48,
        residential: residential,
        native: native,
        source: 'https://my.ippure.com/v1/info',
      );

  testWidgets('idle, loading and failure are explicit', (tester) async {
    await pump(tester, null);
    expect(find.text('测速时更新 IP 质量'), findsOneWidget);
    await pump(tester, const NodeQualityEntry(loading: true));
    expect(find.text('更新中'), findsOneWidget);
    await pump(tester, const NodeQualityEntry(failed: true));
    expect(find.text('检测失败，可重试'), findsOneWidget);
  });

  testWidgets('labels known fields and puts exit and source in tooltip', (
    tester,
  ) async {
    await pump(
      tester,
      NodeQualityEntry(report: report(residential: true, native: true)),
    );
    expect(find.text('风险 48 · 住宅 · 原生'), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('203.0.113.1'));
    expect(tooltip.message, contains('https://my.ippure.com/v1/info'));
  });

  testWidgets(
    'missing fields stay unknown and failed refresh keeps stale label',
    (tester) async {
      await pump(tester, NodeQualityEntry(report: report(), failed: true));
      expect(find.text('上次结果（本次失败） · 风险 48 · 未知 · 未知'), findsOneWidget);
      expect(find.textContaining('住宅'), findsNothing);
    },
  );

  testWidgets('non-residential does not assert datacenter', (tester) async {
    await pump(
      tester,
      NodeQualityEntry(report: report(residential: false, native: false)),
    );
    expect(find.text('风险 48 · 非住宅 · 广播'), findsOneWidget);
  });
}
