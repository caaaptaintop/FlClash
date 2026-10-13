import 'dart:convert';

import 'package:fl_clash/common/node_quality.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

ProbeResult _response(Map<String, Object?> json) =>
    ProbeResult(statusCode: 200, body: jsonEncode(json));

void main() {
  setUpAll(() => registerFallbackValue(const ProbeParams(url: '', timeout: 0)));

  test('reads the observed IPPure schema and detection time', () {
    final checkedAt = DateTime.utc(2026, 10, 13);
    final report = parseNodeQuality(
      _response({
        'ip': '203.0.113.1',
        'asn': 7018,
        'asOrganization': 'CoreNode Innovations LLC',
        'countryCode': 'US',
        'fraudScore': 48,
        'isResidential': true,
        'isBroadcast': false,
      }),
      checkedAt: checkedAt,
    );

    expect(report?.ip, '203.0.113.1');
    expect(report?.checkedAt, checkedAt);
    expect(report?.riskScore, 48);
    expect(report?.residential, isTrue);
    expect(report?.native, isTrue);
    expect(report?.asn, 7018);
    expect(report?.organization, 'CoreNode Innovations LLC');
    expect(report?.countryCode, 'US');
    expect(report?.source, 'https://my.ippure.com/v1/info');
  });

  test('missing or incorrectly typed classifications stay unknown', () {
    for (final fields in [
      <String, Object?>{},
      {'isResidential': 'true', 'isBroadcast': 0, 'fraudScore': '48'},
      {'isResidential': null, 'isBroadcast': null, 'fraudScore': 1.5},
    ]) {
      final report = parseNodeQuality(
        _response({'ip': '203.0.113.1', ...fields}),
      );

      expect(report, isNotNull);
      expect(report?.residential, isNull);
      expect(report?.native, isNull);
      expect(report?.riskScore, isNull);
      expect(report?.asn, isNull);
      expect(report?.organization, isNull);
    }
  });

  test('explicit negative residential and broadcast are not unknown', () {
    final report = parseNodeQuality(
      _response({
        'ip': '2001:db8::1',
        'isResidential': false,
        'isBroadcast': true,
      }),
    );
    expect(report?.residential, isFalse);
    expect(report?.native, isFalse);
  });

  test('risk is accepted only inside 0 through 100', () {
    for (final score in [-1, 0, 100, 101]) {
      final report = parseNodeQuality(
        _response({'ip': '203.0.113.1', 'fraudScore': score}),
      );
      expect(report?.riskScore, score >= 0 && score <= 100 ? score : null);
    }
  });

  test('invalid IPs and hostnames cannot become reports', () {
    for (final ip in [null, 12, '', '999.1.2.3', 'localhost', 'fe80::1%en0']) {
      expect(parseNodeQuality(_response({'ip': ip})), isNull);
    }
  });

  test('failed, malformed and oversized responses cannot become reports', () {
    for (final response in [
      null,
      const ProbeResult(statusCode: 200, body: '{}', error: 'timeout'),
      const ProbeResult(statusCode: 429, body: '{}'),
      const ProbeResult(statusCode: 200, body: 'not JSON'),
      const ProbeResult(statusCode: 200, body: '[]'),
      const ProbeResult(statusCode: 200, body: ''),
      _response({'ip': '203.0.113.1', 'extra': 'x' * (16 * 1024)}),
    ]) {
      expect(parseNodeQuality(response), isNull);
    }
  });

  test('pins the requested node and bounds the core request', () async {
    final core = _MockCore();
    when(
      () => core.probe(any()),
    ).thenAnswer((_) async => _response({'ip': '203.0.113.1'}));

    final report = await lookupNodeQuality(
      CoreController.scoped(core),
      'HK-01',
    );
    final params =
        verify(() => core.probe(captureAny())).captured.single as ProbeParams;

    expect(report, isNotNull);
    expect(params.proxyName, 'HK-01');
    expect(params.url, 'https://my.ippure.com/v1/info');
    expect(params.timeout, 8000);
    expect(params.maxBody, 16 * 1024);
    verifyNoMoreInteractions(core);
  });

  test('blank node names cannot silently use the current route', () async {
    final core = _MockCore();
    expect(await lookupNodeQuality(CoreController.scoped(core), ' '), isNull);
    verifyNever(() => core.probe(any()));
  });

  test('quality targets exclude only exact reserved names and blank names', () {
    for (final name in [
      '',
      ' \t ',
      'DIRECT',
      'REJECT',
      'REJECT-DROP',
      'PASS',
      'COMPATIBLE',
    ]) {
      expect(isNodeQualityTarget(name), isFalse, reason: name);
    }
    for (final name in ['direct', 'DIRECT-01', ' DIRECT ', 'HK-01']) {
      expect(isNodeQualityTarget(name), isTrue, reason: name);
    }
  });

  test('direct lookup never probes built-in non-proxy outbounds', () async {
    final core = _MockCore();
    for (final name in [
      'DIRECT',
      'REJECT',
      'REJECT-DROP',
      'PASS',
      'COMPATIBLE',
    ]) {
      expect(
        await lookupNodeQuality(CoreController.scoped(core), name),
        isNull,
      );
    }
    verifyNever(() => core.probe(any()));
  });
}
