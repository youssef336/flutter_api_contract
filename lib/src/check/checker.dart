import '../config.dart';
import '../dart/models.dart';
import '../spec/schema.dart';
import 'finding.dart';
import 'levenshtein.dart';
import 'matcher.dart';

/// Compares every matched model with its schema.
class ContractChecker {
  ContractChecker({
    required this.project,
    required this.spec,
    required this.config,
  });

  final DartProject project;
  final ApiSpec spec;
  final ContractConfig config;

  late final MatchResult _match = matchModels(project, spec, config);

  /// Result of the model/schema pairing (available after [check]).
  MatchResult get match => _match;

  /// Runs all checks. Findings are sorted by model, severity, key.
  List<Finding> check() {
    final findings = <Finding>[];
    for (final (model, message) in _match.configErrors) {
      findings.add(
        Finding(
          severity: Severity.error,
          code: Codes.unknownSchema,
          model: model.name,
          message: message,
          file: model.file,
          line: model.line,
        ),
      );
    }
    for (final e in _match.unmatched.entries) {
      final model = e.key;
      findings.add(
        Finding(
          severity: Severity.warning,
          code: Codes.unmatchedModel,
          model: model.name,
          message:
              'No schema matches ${model.name} '
              '(tried ${e.value.map((n) => '"$n"').join(', ')}).',
          suggestion: _schemaSuggestion(model.name),
          file: model.file,
          line: model.line,
        ),
      );
    }
    final schemaOfModel = {
      for (final m in _match.matches) m.model.name: m.schemaName,
    };
    for (final m in _match.matches) {
      findings.addAll(_checkModel(m, schemaOfModel));
    }
    findings.sort((a, b) {
      final byModel = a.model.compareTo(b.model);
      if (byModel != 0) return byModel;
      final bySeverity = a.severity.index.compareTo(b.severity.index);
      if (bySeverity != 0) return bySeverity;
      return (a.key ?? '').compareTo(b.key ?? '');
    });
    return findings;
  }

  String? _schemaSuggestion(String modelName) {
    final hit = closest(modelName, spec.schemas.keys);
    return hit == null
        ? null
        : 'closest schema is "$hit" — map it in api_contract.yaml '
              '(models: {$modelName: $hit})';
  }

  List<Finding> _checkModel(ModelMatch m, Map<String, String> schemaOfModel) {
    final model = m.model;
    final root = spec.resolve(m.schema);
    final findings = <Finding>[];

    Finding finding(
      Severity severity,
      String code,
      String message, {
      String? key,
      String? suggestion,
      int? line,
    }) => Finding(
      severity: severity,
      code: code,
      model: model.name,
      schema: m.schemaName,
      key: key,
      message: message,
      suggestion: suggestion,
      file: model.file,
      line: line ?? model.line,
    );

    if (root.properties.isEmpty) {
      // Free-form object, primitive or oneOf: nothing to compare key-wise.
      return findings;
    }

    final readTopLevel = <String>{};
    for (final read in model.reads) {
      readTopLevel.add(read.key);
      if (_ignored(model.name, read)) continue;

      // Walk the key path through the schema.
      var parent = root;
      var parentName = m.schemaName;
      SchemaNode? prop;
      var missingAt = -1;
      final segments = [read.key, ...read.path];
      for (var i = 0; i < segments.length; i++) {
        if (i > 0) {
          final resolved = spec.resolve(prop!);
          if (resolved.properties.isEmpty) {
            prop = null; // free-form: cannot say more
            break;
          }
          parentName = resolved.ref ?? '$parentName.${segments[i - 1]}';
          parent = resolved;
        }
        prop = parent.properties[segments[i]];
        if (prop == null) {
          missingAt = i;
          break;
        }
      }

      final key = read.displayKey;
      if (missingAt >= 0) {
        final segment = segments[missingAt];
        final hint = closest(segment, parent.properties.keys);
        findings.add(
          finding(
            read.nullSafe ? Severity.warning : Severity.error,
            Codes.missingInSchema,
            read.nullSafe
                ? '"$key" is read by the app but $parentName has no '
                      '"$segment" — it will always be null.'
                : '"$key" is read by the app but $parentName has no '
                      '"$segment", and the read throws when it is absent '
                      '(CRASH RISK).',
            key: key,
            suggestion: hint == null
                ? null
                : 'did you mean "$hint"? (likely a backend rename)',
            line: read.line,
          ),
        );
        continue;
      }
      if (prop == null) continue;

      final resolved = spec.resolve(prop);
      final lastSegment = segments.last;
      final optional = !parent.required.contains(lastSegment);
      final nullable = prop.nullable || resolved.nullable;

      if ((optional || nullable) && !read.nullSafe) {
        final why = [
          if (nullable) 'nullable',
          if (optional) 'not required',
        ].join(' and ');
        final typeLabel = read.type == null ? '' : ' `${read.type}`';
        findings.add(
          finding(
            Severity.error,
            Codes.nullableMismatch,
            '"$key" is $why in $parentName, but the app reads it as '
            'non-nullable$typeLabel with no default (CRASH RISK).',
            key: key,
            suggestion: read.fieldName == null
                ? 'make the Dart value nullable or give it a default'
                : 'make `${read.fieldName}` nullable or give it a default '
                      '(`??`, @Default, defaultValue)',
            line: read.line,
          ),
        );
      }

      final type = read.type;
      if (type != null && !read.customConverter) {
        final problem = _typeProblem(type, prop, model.kind, schemaOfModel);
        if (problem != null) {
          findings.add(
            finding(
              problem.$1,
              Codes.typeMismatch,
              '"$key" is `$type` in Dart but ${prop.describe()} in '
              '$parentName${problem.$2.isEmpty ? '' : ': ${problem.$2}'}.',
              key: key,
              line: read.line,
            ),
          );
        }
      }

      findings.addAll(_enumFindings(read, prop, model, m.schemaName));
    }

    for (final name in root.required) {
      if (readTopLevel.contains(name)) continue;
      if (config.ignore.contains('${model.name}.$name')) continue;
      findings.add(
        finding(
          Severity.info,
          Codes.requiredIgnored,
          '"$name" is required in ${m.schemaName} but ${model.name} never '
          'reads it.',
          key: name,
        ),
      );
    }
    return findings;
  }

  bool _ignored(String model, FieldRead read) =>
      config.ignore.contains('$model.${read.key}') ||
      config.ignore.contains('$model.${read.displayKey}');

  /// Returns (severity, detail) when [type] cannot hold [node]'s JSON.
  (Severity, String)? _typeProblem(
    DartType type,
    SchemaNode node,
    ModelKind kind,
    Map<String, String> schemaOfModel,
  ) {
    final s = spec.resolve(node);
    if (type.isDynamic || s.isUnion) return null;
    if (s.type == JsonType.any && s.ref == null) return null;
    final json = s.type;
    const err = Severity.error;

    switch (type.name) {
      case 'String':
        return json == JsonType.string
            ? null
            : (err, 'a String cannot hold it');
      case 'int':
        if (json == JsonType.integer) return null;
        if (json == JsonType.number) {
          return (
            Severity.warning,
            'the schema allows decimals; a value like 1.5 will not fit an int',
          );
        }
        return (err, 'an int cannot hold it');
      case 'double':
        if (json == JsonType.number || json == JsonType.integer) {
          if (kind == ModelKind.handWritten) {
            return (
              json == JsonType.integer ? err : Severity.warning,
              'whole numbers decode as int, and `as double` throws on them — '
                  'read it as `(json[...] as num).toDouble()`',
            );
          }
          return null;
        }
        return (err, 'a double cannot hold it');
      case 'num':
        return json == JsonType.number || json == JsonType.integer
            ? null
            : (err, 'a num cannot hold it');
      case 'bool':
        return json == JsonType.boolean ? null : (err, 'a bool cannot hold it');
      case 'DateTime':
        if (json == JsonType.string) return null;
        return (err, 'DateTime is parsed from a string');
      case 'List' || 'Iterable' || 'Set':
        if (json != JsonType.array) return (err, 'expected an array');
        if (type.args.isNotEmpty && s.items != null) {
          final inner = _typeProblem(
            type.args.first,
            s.items!,
            kind,
            schemaOfModel,
          );
          if (inner != null) return (inner.$1, 'list items: ${inner.$2}');
        }
        return null;
      case 'Map':
        return json == JsonType.object ? null : (err, 'expected an object');
    }

    if (project.enums.containsKey(type.name)) {
      return json == JsonType.string || json == JsonType.integer
          ? null
          : (err, 'enum ${type.name} expects a string or integer');
    }
    if (project.models.containsKey(type.name)) {
      if (json != JsonType.object) {
        return (err, 'nested model ${type.name} expects an object');
      }
      final mapped = schemaOfModel[type.name];
      if (mapped != null && s.ref != null && mapped != s.ref) {
        return (
          Severity.warning,
          '${type.name} is checked against $mapped, but this field refers to '
              '${s.ref}',
        );
      }
      return null;
    }
    return null;
  }

  List<Finding> _enumFindings(
    FieldRead read,
    SchemaNode prop,
    DartModel model,
    String schemaName,
  ) {
    final type = read.type;
    var enumName = read.enumName;
    var schemaNode = spec.resolve(prop);
    if (enumName == null && type != null) {
      if (project.enums.containsKey(type.name)) {
        enumName = type.name;
      } else if (type.args.isNotEmpty &&
          project.enums.containsKey(type.args.first.name)) {
        enumName = type.args.first.name;
      }
    }
    if (schemaNode.type == JsonType.array && schemaNode.items != null) {
      schemaNode = spec.resolve(schemaNode.items!);
    }
    final dartEnum = enumName == null ? null : project.enums[enumName];
    final schemaValues = schemaNode.enumValues;
    if (dartEnum == null || schemaValues == null || read.customConverter) {
      return const [];
    }

    final dartSet = dartEnum.values.map((v) => v.toString()).toSet();
    final schemaSet = schemaValues.map((v) => v.toString()).toSet();
    final unhandled = schemaSet.difference(dartSet).toList()..sort();
    final extra = dartSet.difference(schemaSet).toList()..sort();
    final key = read.displayKey;
    final findings = <Finding>[];
    final fallback = read.enumFallback || dartEnum.safeParse;
    String list(List<String> v) => v.map((e) => '"$e"').join(', ');

    if (unhandled.isNotEmpty) {
      findings.add(
        Finding(
          severity: fallback ? Severity.warning : Severity.error,
          code: Codes.enumUnhandled,
          model: model.name,
          schema: schemaName,
          key: key,
          message: fallback
              ? 'enum ${dartEnum.name} does not know ${list(unhandled)} '
                    'from the schema; unknown values fall back to a default.'
              : 'enum ${dartEnum.name} does not know ${list(unhandled)} '
                    'from the schema, and parsing an unknown value throws '
                    '(CRASH RISK).',
          suggestion: fallback
              ? 'add the missing values to ${dartEnum.name}'
              : 'add the values, or a fallback '
                    '(@JsonKey(unknownEnumValue: ...) / orElse:)',
          file: model.file,
          line: read.line,
        ),
      );
    }
    if (extra.isNotEmpty) {
      findings.add(
        Finding(
          severity: Severity.info,
          code: Codes.enumExtra,
          model: model.name,
          schema: schemaName,
          key: key,
          message:
              'enum ${dartEnum.name} has ${list(extra)}, which the schema '
              'never sends.',
          file: dartEnum.file,
          line: dartEnum.line,
        ),
      );
    }
    return findings;
  }
}
