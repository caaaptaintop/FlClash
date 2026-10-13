import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/node_quality.dart';
import 'package:fl_clash/providers/node_quality.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _riskBounds = [0, 15, 25, 40, 50, 70, 100];
const _riskColors = [
  Color(0xff166534),
  Color(0xff22c55e),
  Color(0xff84cc16),
  Color(0xffeab308),
  Color(0xfff97316),
  Color(0xffdc2626),
];

// IPPure ColorMap assigns a boundary score to the preceding band.
int _riskBand(int score) => switch (score) {
  <= 15 => 0,
  <= 25 => 1,
  <= 40 => 2,
  <= 50 => 3,
  <= 70 => 4,
  _ => 5,
};

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
    final score = report?.riskScore;
    final band = score == null ? null : _riskBand(score);
    final level = band == null
        ? l10n.nodeQualityUnknown
        : [
            l10n.nodeQualityExtremelyClean,
            l10n.nodeQualityClean,
            l10n.nodeQualityNeutral,
            l10n.nodeQualityLowRisk,
            l10n.nodeQualityModerateRisk,
            l10n.nodeQualityExtremeRisk,
          ][band];
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
        : score == null
        ? '${l10n.nodeQualityRisk} ${l10n.nodeQualityUnknown}'
        : '${l10n.nodeQualityRisk} $score/100 · $level';
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
        level,
        '$residential · $native',
        if (report.countryCode != null) report.countryCode!,
        if (report.asn != null) 'AS${report.asn}',
        if (report.organization != null) report.organization!,
        '${l10n.nodeQualityCheckedAt}: ${report.checkedAt.toLocal()}',
        '${l10n.nodeQualitySource}: ${report.source}',
      ],
      l10n.nodeQualityExplanation,
    ].join('\n');
    final style = context.textTheme.labelSmall;
    final color = band == null
        ? context.colorScheme.onSurfaceVariant
        : context.colorScheme.brightness == Brightness.dark
        ? Color.lerp(_riskColors[band], const Color(0xffffffff), 0.25)
        : Color.lerp(_riskColors[band], const Color(0xff000000), 0.3);
    final attributes = '$residential · $native';
    return Tooltip(
      message: details,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style?.copyWith(color: color),
          ),
          if (report != null) ...[
            const SizedBox(height: 4),
            Text(
              status.isEmpty ? attributes : '$status · $attributes',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
            if (score != null) ...[
              const SizedBox(height: 4),
              _RiskScale(score: score),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('0', style: style),
                  Flexible(
                    child: Text(
                      l10n.nodeQualityLowerIsBetter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                  Text('100', style: style),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _RiskScale extends StatelessWidget {
  const _RiskScale({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        key: const ValueKey('node-quality-scale'),
        height: 12,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Positioned.fill(
                top: 3,
                bottom: 3,
                child: ClipPath(
                  clipper: const ShapeBorderClipper(shape: AppShape.full),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < _riskColors.length; i++)
                        Expanded(
                          flex: _riskBounds[i + 1] - _riskBounds[i],
                          child: ColoredBox(color: _riskColors[i]),
                        ),
                    ],
                  ),
                ),
              ),
              Positioned(
                key: const ValueKey('node-quality-score-marker'),
                left: (constraints.maxWidth - 4) * score / 100,
                top: 0,
                bottom: 0,
                width: 4,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: context.colorScheme.onSurface,
                    shape: AppShape.full.copyWith(
                      side: BorderSide(color: context.colorScheme.surface),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
