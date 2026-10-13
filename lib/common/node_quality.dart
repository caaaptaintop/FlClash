import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/models/core.dart';
import 'package:flutter/foundation.dart';

const _ippureUrl = 'https://my.ippure.com/v1/info';
const _maxBody = 16 * 1024;
const _nonQualityTargets = {
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'PASS',
  'COMPATIBLE',
};

bool isNodeQualityTarget(String name) =>
    name.trim().isNotEmpty && !_nonQualityTargets.contains(name);

@immutable
class NodeQualityReport {
  const NodeQualityReport({
    required this.ip,
    required this.checkedAt,
    this.riskScore,
    this.residential,
    this.native,
    required this.source,
    this.countryCode,
    this.organization,
    this.asn,
  }) : assert(riskScore == null || (riskScore >= 0 && riskScore <= 100));

  final String ip;
  final DateTime checkedAt;
  final int? riskScore;
  final bool? residential;
  final bool? native;
  final String source;
  final String? countryCode;
  final String? organization;
  final int? asn;
}

Future<NodeQualityReport?> lookupNodeQuality(
  CoreController core,
  String proxyName, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (!isNodeQualityTarget(proxyName)) {
    return null;
  }
  final result = await core
      .probe(
        ProbeParams(
          url: _ippureUrl,
          proxyName: proxyName,
          headers: const {'Accept': 'application/json'},
          timeout: timeout.inMilliseconds,
          maxBody: _maxBody,
        ),
      )
      .timeout(timeout * 2 + const Duration(seconds: 1));
  return parseNodeQuality(result);
}

NodeQualityReport? parseNodeQuality(
  ProbeResult? result, {
  DateTime? checkedAt,
}) {
  if (result == null ||
      result.error != null ||
      result.statusCode != HttpStatus.ok ||
      result.body.isEmpty ||
      result.body.length > _maxBody ||
      utf8.encode(result.body).length > _maxBody) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(result.body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  final ip = _text(decoded['ip']);
  if (ip == null || ip.contains('%') || InternetAddress.tryParse(ip) == null) {
    return null;
  }
  final score = decoded['fraudScore'];
  final residential = decoded['isResidential'];
  final broadcast = decoded['isBroadcast'];
  final asn = decoded['asn'];
  return NodeQualityReport(
    ip: ip,
    checkedAt: checkedAt ?? DateTime.now(),
    riskScore: score is int && score >= 0 && score <= 100 ? score : null,
    residential: residential is bool ? residential : null,
    native: broadcast is bool ? !broadcast : null,
    source: _ippureUrl,
    countryCode: _text(decoded['countryCode']),
    organization: _text(decoded['asOrganization']),
    asn: asn is int && asn > 0 ? asn : null,
  );
}

String? _text(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}
