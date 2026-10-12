import 'dart:convert';
import 'dart:io';

import 'package:flutter_api_contract/flutter_api_contract.dart';
import 'package:test/test.dart';

Finding finding(String code, String model, String key, Severity s) => Finding(
  severity: s,
  code: code,
  model: model,
  schema: 'S',
  key: key,
  message: 'msg, with: 100% detail',
  suggestion: 'fix it',
  file: 'lib/a.dart',
  line: 3,
);

void main() {
  final a = finding(Codes.nullableMismatch, 'A', 'x', Severity.error);
  final b = finding(Codes.missingInSchema, 'B', 'y', Severity.warning);
  final c = finding(Codes.requiredIgnored, 'C', 'z', Severity.info);

  group('baseline', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('baseline'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('fingerprint ignores line numbers', () {
      expect(a.fingerprint, 'nullable-mismatch|A|x');
    });

    test('apply splits fresh, accepted and stale', () {
      final r = Baseline({a.fingerprint, 'gone|X|k'}).apply([a, b]);
      expect(r.fresh, [b]);
      expect(r.accepted, [a]);
      expect(r.stale, ['gone|X|k']);
    });

    test('next() creates from everything, then only shrinks', () {
      final created = Baseline.next(Baseline({}), [a, b], exists: false);
      expect(created.entries, {a.fingerprint, b.fingerprint});
      final shrunk = Baseline.next(created, [a, c], exists: true);
      expect(shrunk.entries, {a.fingerprint});
    });

    test('save/load round trip; missing file is empty; bad JSON throws', () {
      final path = '${tmp.path}/b.json';
      expect(Baseline.load(path).entries, isEmpty);
      Baseline({b.fingerprint, a.fingerprint}).save(path);
      final doc = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(doc['findings'], [b.fingerprint, a.fingerprint]..sort());
      expect(Baseline.load(path).entries, {a.fingerprint, b.fingerprint});
      File(path).writeAsStringSync('nope');
      expect(() => Baseline.load(path), throwsFormatException);
    });
  });

  group('report formats', () {
    final report = Report(
      specLabel: 'OpenAPI 3.0.0',
      specSource: 'spec.json',
      schemaCount: 2,
      match: MatchResult(
        matches: const [],
        unmatched: const {},
        skipped: const [],
        configErrors: const [],
      ),
      findings: [a, b, c],
      baselined: 1,
      staleBaseline: const ['old|M|k'],
    );

    test('text groups by model and summarizes', () {
      final text = report.render(ReportFormat.text);
      expect(text, contains('A  lib/a.dart'));
      expect(text, contains('nullable-mismatch  x  lib/a.dart:3'));
      expect(text, contains('→ fix it'));
      expect(text, contains('1 error · 1 warning · 1 info (1 baselined)'));
      expect(text, contains('--update-baseline'));
      expect(text, isNot(contains('\x1B[')));
      expect(report.render(ReportFormat.text, color: true), contains('\x1B['));
    });

    test('markdown is a table', () {
      final md = report.render(ReportFormat.markdown);
      expect(md, contains('| | Model | Key | Finding | Where |'));
      expect(md, contains('| A → S | `x` |'));
    });

    test('json is machine readable', () {
      final doc = jsonDecode(report.render(ReportFormat.json)) as Map;
      final summary = doc['summary'] as Map;
      expect(summary['errors'], 1);
      expect(summary['baselined'], 1);
      final findings = doc['findings'] as List;
      expect((findings.first as Map)['fingerprint'], a.fingerprint);
    });

    test('github annotations are escaped', () {
      final gh = report.render(ReportFormat.github);
      expect(
        gh,
        contains(
          '::error file=lib/a.dart,line=3,'
          'title=api_contract nullable-mismatch%3A A.x::'
          'msg, with: 100%25 detail → fix it',
        ),
      );
      expect(gh, contains('::warning '));
      expect(gh, contains('::notice '));
    });
  });
}
