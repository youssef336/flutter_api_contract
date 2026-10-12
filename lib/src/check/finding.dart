/// How bad a finding is. Only [error] fails the run by default.
enum Severity { error, warning, info }

/// Stable finding codes (also used in baselines and `--format json`).
abstract final class Codes {
  /// The app reads a key the schema does not have (often a rename).
  static const missingInSchema = 'missing-in-schema';

  /// The schema requires a field the app never reads.
  static const requiredIgnored = 'required-ignored';

  /// The schema allows null/absent but the Dart read cannot handle it.
  static const nullableMismatch = 'nullable-mismatch';

  /// The Dart type cannot hold the JSON type.
  static const typeMismatch = 'type-mismatch';

  /// The schema has enum values the Dart enum does not know.
  static const enumUnhandled = 'enum-unhandled';

  /// The Dart enum has values the schema never sends.
  static const enumExtra = 'enum-extra';

  /// No schema could be matched to the model.
  static const unmatchedModel = 'unmatched-model';

  /// `api_contract.yaml` points at a schema or endpoint that does not exist.
  static const unknownSchema = 'unknown-schema';
}

/// One drift between a Dart model and the API schema.
class Finding {
  Finding({
    required this.severity,
    required this.code,
    required this.model,
    required this.message,
    required this.file,
    required this.line,
    this.schema,
    this.key,
    this.suggestion,
  });

  final Severity severity;
  final String code;
  final String model;
  final String? schema;

  /// JSON key (dotted for nested reads), when the finding is about one.
  final String? key;
  final String message;
  final String? suggestion;
  final String file;
  final int line;

  /// Line-number-free identity used by baselines.
  String get fingerprint => '$code|$model|${key ?? ''}';

  Map<String, Object?> toJson() => {
    'severity': severity.name,
    'code': code,
    'model': model,
    'schema': schema,
    'key': key,
    'message': message,
    'suggestion': suggestion,
    'file': file,
    'line': line,
    'fingerprint': fingerprint,
  };
}
