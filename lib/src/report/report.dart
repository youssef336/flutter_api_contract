import 'dart:convert';

import '../check/finding.dart';
import '../check/matcher.dart';

/// Output formats for `--format`.
enum ReportFormat { text, markdown, json, github }

/// Everything a reporter needs.
class Report {
  Report({
    required this.specLabel,
    required this.specSource,
    required this.schemaCount,
    required this.match,
    required this.findings,
    this.baselined = 0,
    this.staleBaseline = const [],
  });

  final String specLabel;
  final String specSource;
  final int schemaCount;
  final MatchResult match;

  /// Findings to report (already filtered by the baseline).
  final List<Finding> findings;
  final int baselined;
  final List<String> staleBaseline;

  int count(Severity s) => findings.where((f) => f.severity == s).length;

  int get modelCount =>
      match.matches.length +
      match.unmatched.length +
      match.configErrors.length +
      match.skipped.length;

  String render(ReportFormat format, {bool color = false}) => switch (format) {
    ReportFormat.text => _text(color),
    ReportFormat.markdown => _markdown(),
    ReportFormat.json => _json(),
    ReportFormat.github => _github(),
  };

  String _summaryLine() {
    String plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
    final parts = [
      plural(count(Severity.error), 'error'),
      plural(count(Severity.warning), 'warning'),
      '${count(Severity.info)} info',
    ];
    final extra = baselined > 0 ? ' ($baselined baselined)' : '';
    return '${parts.join(' · ')}$extra';
  }

  String _text(bool color) {
    String paint(String s, String code) => color ? '\x1B[${code}m$s\x1B[0m' : s;
    String sev(Severity s) => switch (s) {
      Severity.error => paint('error  ', '31;1'),
      Severity.warning => paint('warning', '33;1'),
      Severity.info => paint('info   ', '36'),
    };

    final b = StringBuffer()
      ..writeln(
        '${paint('API contract check', '1')} · $specLabel ($specSource) · '
        '$schemaCount schemas · $modelCount models',
      );

    final byModel = <String, List<Finding>>{};
    for (final f in findings) {
      byModel.putIfAbsent(f.model, () => []).add(f);
    }
    final schemaOf = {
      for (final m in match.matches) m.model.name: m.schemaName,
    };
    for (final e in byModel.entries) {
      final first = e.value.first;
      final schema = schemaOf[e.key];
      b
        ..writeln()
        ..writeln(
          '${paint(e.key, '1')}${schema == null ? '' : ' → $schema'}  '
          '${paint(first.file, '2')}',
        );
      for (final f in e.value) {
        final key = f.key == null ? '' : '  ${paint(f.key!, '1')}';
        b
          ..writeln(
            '  ${sev(f.severity)}  ${f.code}$key  '
            '${paint('${f.file}:${f.line}', '2')}',
          )
          ..writeln('           ${f.message}');
        if (f.suggestion != null) {
          b.writeln('           ${paint('→ ${f.suggestion}', '32')}');
        }
      }
    }
    final clean = [
      for (final m in match.matches)
        if (!byModel.containsKey(m.model.name))
          '${m.model.name} → ${m.schemaName}',
    ];
    if (clean.isNotEmpty) {
      b
        ..writeln()
        ..writeln(paint('No drift: ${clean.join(', ')}', '32'));
    }
    if (match.skipped.isNotEmpty) {
      b.writeln(
        paint(
          'Skipped by config: ${match.skipped.map((m) => m.name).join(', ')}',
          '2',
        ),
      );
    }
    if (staleBaseline.isNotEmpty) {
      b.writeln(
        paint(
          '${staleBaseline.length} baseline entr'
              '${staleBaseline.length == 1 ? 'y is' : 'ies are'} fixed — run '
              'with --update-baseline to shrink the baseline.',
          '32',
        ),
      );
    }
    b
      ..writeln()
      ..writeln(_summaryLine());
    return b.toString();
  }

  String _markdown() {
    final b = StringBuffer()
      ..writeln('## API contract check')
      ..writeln()
      ..writeln(
        '`$specLabel` · $schemaCount schemas · $modelCount models · '
        '**${_summaryLine()}**',
      )
      ..writeln();
    if (findings.isEmpty) {
      b.writeln('No drift between the Dart models and the API schema.');
    } else {
      b
        ..writeln('| | Model | Key | Finding | Where |')
        ..writeln('|---|---|---|---|---|');
      for (final f in findings) {
        final icon = switch (f.severity) {
          Severity.error => '🔴',
          Severity.warning => '🟡',
          Severity.info => '🔵',
        };
        final model = f.schema == null ? f.model : '${f.model} → ${f.schema}';
        final message = f.suggestion == null
            ? f.message
            : '${f.message}<br>→ ${f.suggestion}';
        b.writeln(
          '| $icon ${f.severity.name} | $model | '
          '${f.key == null ? '' : '`${f.key}`'} | '
          '**${f.code}** ${_mdEscape(message)} | `${f.file}:${f.line}` |',
        );
      }
    }
    if (staleBaseline.isNotEmpty) {
      b
        ..writeln()
        ..writeln(
          '${staleBaseline.length} baseline entries are fixed; '
          'run `--update-baseline` to shrink the baseline.',
        );
    }
    return b.toString();
  }

  String _json() {
    final doc = {
      'spec': {
        'source': specSource,
        'version': specLabel,
        'schemas': schemaCount,
      },
      'summary': {
        'errors': count(Severity.error),
        'warnings': count(Severity.warning),
        'infos': count(Severity.info),
        'baselined': baselined,
        'staleBaseline': staleBaseline,
      },
      'models': [
        for (final m in match.matches)
          {
            'model': m.model.name,
            'schema': m.schemaName,
            'via': m.via.name,
            'kind': m.model.kind.name,
            'file': m.model.file,
          },
      ],
      'unmatched': [for (final m in match.unmatched.keys) m.name],
      'skipped': [for (final m in match.skipped) m.name],
      'findings': [for (final f in findings) f.toJson()],
    };
    return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
  }

  String _github() {
    final b = StringBuffer();
    for (final f in findings) {
      final level = switch (f.severity) {
        Severity.error => 'error',
        Severity.warning => 'warning',
        Severity.info => 'notice',
      };
      final title =
          'api_contract ${f.code}: ${f.model}'
          '${f.key == null ? '' : '.${f.key}'}';
      final message = f.suggestion == null
          ? f.message
          : '${f.message} → ${f.suggestion}';
      b.writeln(
        '::$level file=${_ghProp(f.file)},line=${f.line},'
        'title=${_ghProp(title)}::${_ghData(message)}',
      );
    }
    b.writeln('API contract check: ${_summaryLine()}');
    return b.toString();
  }
}

String _mdEscape(String s) => s.replaceAll('|', r'\|').replaceAll('\n', ' ');

String _ghData(String s) =>
    s.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');

String _ghProp(String s) =>
    _ghData(s).replaceAll(':', '%3A').replaceAll(',', '%2C');
