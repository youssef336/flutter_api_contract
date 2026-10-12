import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'check/baseline.dart';
import 'check/checker.dart';
import 'check/finding.dart';
import 'config.dart';
import 'dart/extractor.dart';
import 'report/report.dart';
import 'spec/loader.dart';

/// Package version, printed by `--version`.
const packageVersion = '0.1.0';

/// Exit codes.
abstract final class ExitCodes {
  static const ok = 0;
  static const drift = 1;
  static const usage = 2;
}

ArgParser buildParser() => ArgParser()
  ..addOption(
    'spec',
    abbr: 's',
    help:
        'OpenAPI 3.x / Swagger 2.0 spec: file path or http(s) URL '
        '(JSON or YAML). Overrides "spec:" in the config.',
  )
  ..addOption(
    'project',
    abbr: 'p',
    help: 'Root of the Dart/Flutter project.',
    defaultsTo: '.',
  )
  ..addOption(
    'config',
    abbr: 'c',
    help: 'Config file, relative to --project.',
    defaultsTo: 'api_contract.yaml',
  )
  ..addOption(
    'format',
    abbr: 'f',
    allowed: ReportFormat.values.map((f) => f.name),
    defaultsTo: 'text',
    help: 'Output format.',
  )
  ..addOption(
    'fail-on',
    allowed: ['error', 'warning', 'never'],
    defaultsTo: 'error',
    help: 'Lowest severity that makes the exit code 1.',
  )
  ..addOption(
    'baseline',
    abbr: 'b',
    help: 'JSON file of accepted drift (overrides "baseline:" in config).',
  )
  ..addFlag(
    'update-baseline',
    negatable: false,
    help:
        'Create the baseline, or shrink it to the drift that still exists '
        '(never grows an existing baseline).',
  )
  ..addMultiOption(
    'header',
    abbr: 'H',
    help:
        'Extra header for downloading the spec, e.g. '
        '"Authorization: Bearer xyz". Repeatable.',
  )
  ..addFlag('color', defaultsTo: null, help: 'Force ANSI colors on/off.')
  ..addFlag('version', negatable: false, help: 'Print the version.')
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

/// Runs the CLI and returns the exit code.
Future<int> runCli(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final parser = buildParser();

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderrSink
      ..writeln(e.message)
      ..writeln()
      ..writeln(_usage(parser));
    return ExitCodes.usage;
  }
  if (args.flag('help')) {
    stdoutSink.writeln(_usage(parser));
    return ExitCodes.ok;
  }
  if (args.flag('version')) {
    stdoutSink.writeln('api_contract $packageVersion');
    return ExitCodes.ok;
  }

  final root = p.normalize(p.absolute(args.option('project')!));
  final configPath = p.join(root, args.option('config')!);
  final configExplicit = args.wasParsed('config');

  try {
    final config = ContractConfig.load(configPath, optional: !configExplicit);
    final specSource = args.option('spec') ?? config.spec;
    if (specSource == null) {
      stderrSink.writeln(
        'No spec given. Pass --spec <file-or-url> or set "spec:" in '
        '${p.relative(configPath)}.',
      );
      return ExitCodes.usage;
    }
    final resolvedSpec = _isUrl(specSource) || p.isAbsolute(specSource)
        ? specSource
        : (args.option('spec') != null ? specSource : p.join(root, specSource));

    final headers = {...config.headers};
    for (final h in args.multiOption('header')) {
      final i = h.indexOf(':');
      if (i <= 0) {
        stderrSink.writeln('Bad --header "$h": expected "Name: value".');
        return ExitCodes.usage;
      }
      headers[h.substring(0, i).trim()] = h.substring(i + 1).trim();
    }

    final spec = await loadSpec(resolvedSpec, headers: headers);
    final project = extractProject(
      root,
      paths: config.paths,
      exclude: config.exclude,
    );
    final checker = ContractChecker(
      project: project,
      spec: spec,
      config: config,
    );
    var findings = checker.check();

    final baselineOption = args.option('baseline') ?? config.baseline;
    final baselinePath = baselineOption == null
        ? null
        : (p.isAbsolute(baselineOption)
              ? baselineOption
              : p.join(root, baselineOption));
    var baselined = 0;
    var stale = const <String>[];
    if (args.flag('update-baseline')) {
      if (baselinePath == null) {
        stderrSink.writeln('--update-baseline needs --baseline <file>.');
        return ExitCodes.usage;
      }
      final exists = File(baselinePath).existsSync();
      final current = Baseline.load(baselinePath);
      final next = Baseline.next(current, findings, exists: exists);
      next.save(baselinePath);
      final added = findings
          .where((f) => !next.entries.contains(f.fingerprint))
          .length;
      stderrSink.writeln(
        exists
            ? 'Baseline ${p.relative(baselinePath)}: '
                  '${current.entries.length} → ${next.entries.length} entries'
                  '${added > 0 ? ' ($added new finding(s) not added: the '
                            'baseline only shrinks)' : ''}.'
            : 'Baseline ${p.relative(baselinePath)} created with '
                  '${next.entries.length} entries.',
      );
    }
    if (baselinePath != null) {
      final result = Baseline.load(baselinePath).apply(findings);
      findings = result.fresh;
      baselined = result.accepted.length;
      stale = result.stale;
    }

    final format = ReportFormat.values.byName(args.option('format')!);
    final color =
        (args['color'] as bool?) ??
        (out == null &&
            stdout.hasTerminal &&
            stdout.supportsAnsiEscapes &&
            !Platform.environment.containsKey('NO_COLOR'));
    final report = Report(
      specLabel: spec.label,
      specSource: _isUrl(specSource) ? specSource : p.basename(specSource),
      schemaCount: spec.schemas.length,
      match: checker.match,
      findings: findings,
      baselined: baselined,
      staleBaseline: stale,
    );
    stdoutSink.write(report.render(format, color: color));

    final failOn = args.option('fail-on')!;
    final failing = switch (failOn) {
      'never' => false,
      'warning' => findings.any((f) => f.severity != Severity.info),
      _ => findings.any((f) => f.severity == Severity.error),
    };
    return failing ? ExitCodes.drift : ExitCodes.ok;
  } on SpecException catch (e) {
    stderrSink.writeln(e.message);
    return ExitCodes.usage;
  } on ConfigException catch (e) {
    stderrSink.writeln(e.message);
    return ExitCodes.usage;
  } on FormatException catch (e) {
    stderrSink.writeln(e.message);
    return ExitCodes.usage;
  }
}

bool _isUrl(String s) => s.startsWith('http://') || s.startsWith('https://');

String _usage(ArgParser parser) =>
    '''
api_contract — catch drift between Dart models and an OpenAPI/Swagger spec.

Usage: api_contract --spec <file-or-url> [options]

${parser.usage}

Exit codes: 0 no failing drift · 1 drift at --fail-on level · 2 usage/spec error''';
