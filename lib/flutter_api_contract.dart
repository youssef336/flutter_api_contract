/// Detect drift between Dart models and an OpenAPI/Swagger schema.
library;

export 'src/check/baseline.dart';
export 'src/check/checker.dart';
export 'src/check/finding.dart';
export 'src/check/levenshtein.dart' show closest, levenshtein;
export 'src/check/matcher.dart';
export 'src/cli.dart' show ExitCodes, packageVersion, runCli;
export 'src/config.dart';
export 'src/dart/extractor.dart'
    show extractFromSources, extractProject, readGlobalFieldRename;
export 'src/dart/models.dart';
export 'src/dart/rename.dart';
export 'src/report/report.dart';
export 'src/spec/loader.dart';
export 'src/spec/schema.dart';
