import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/node_quality.dart';
import 'package:fl_clash/providers/node_quality.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NodeQualitySummary extends ConsumerWidget {
  const NodeQualitySummary({super.key, required this.proxyName});

  final String proxyName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final effectiveName = ref.watch(
      realSelectedProxyStateProvider(
        proxyName,
      ).select((value) => value.proxyName),
    );
    if (!isNodeQualityTarget(effectiveName)) {
      return const SizedBox.shrink();
    }
    final entry = ref.watch(
      nodeQualityProvider.select((value) => value[effectiveName]),
    );
    final l10n = context.appLocalizations;
    final report = entry?.report;
    final residential = switch (report?.residential) {
      true => l10n.nodeQualityResidential,
      false => l10n.nodeQualityNonResidential,
      null => l10n.nodeQualityUnknown,
    };
    final native = switch (report?.native) {
      true => l10n.nodeQualityNative,
      false => l10n.nodeQualityBroadcast,
      null => l10n.nodeQualityUnknown,
    };
    final summary = report == null
        ? entry?.loading == true
              ? l10n.nodeQualityLoading
              : entry?.failed == true
              ? l10n.nodeQualityFailed
              : l10n.nodeQualityIdle
        : '${l10n.nodeQualityRisk} ${report.riskScore ?? "?"} · $residential · $native';
    final status = entry?.loading == true
        ? l10n.nodeQualityLoading
        : entry?.failed == true
        ? l10n.nodeQualityStale
        : '';
    final details = [
      if (status.isNotEmpty) status,
      if (report != null) ...[
        'IP: ${report.ip}',
        '${l10n.nodeQualityRisk}: ${report.riskScore ?? l10n.nodeQualityUnknown}/100',
        '$residential · $native',
        if (report.countryCode != null) report.countryCode!,
        if (report.asn != null) 'AS${report.asn}',
        if (report.organization != null) report.organization!,
        '${l10n.nodeQualityCheckedAt}: ${report.checkedAt.toLocal()}',
        '${l10n.nodeQualitySource}: ${report.source}',
      ],
      l10n.nodeQualityExplanation,
    ].join('\n');
    return Tooltip(
      message: details,
      child: Text(
        status.isEmpty || report == null ? summary : '$status · $summary',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.labelSmall?.copyWith(
          color: report?.riskScore != null && report!.riskScore! >= 70
              ? context.colorScheme.error
              : context.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
