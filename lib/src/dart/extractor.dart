import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../glob.dart';
import 'hand_written.dart';
import 'models.dart';
import 'rename.dart';

/// Scans [root] for Dart models and enums.
///
/// [paths] are folders relative to [root] (default `lib`). Generated files
/// (`*.g.dart`, `*.freezed.dart`, ...) and anything matching [exclude] are
/// skipped. The global `field_rename` from `build.yaml` is honoured.
DartProject extractProject(
  String root, {
  List<String> paths = const ['lib'],
  List<String> exclude = const [],
}) {
  final excludeGlobs = exclude.map(Glob.new).toList();
  final sources = <String, String>{};
  for (final rel in paths) {
    final dir = Directory(p.join(root, rel));
    final single = File(p.join(root, rel));
    final entities = dir.existsSync()
        ? dir.listSync(recursive: true, followLinks: false)
        : single.existsSync()
        ? [single]
        : const <FileSystemEntity>[];
    for (final entity in entities) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final relPath = p.relative(entity.path, from: root).replaceAll(r'\', '/');
      if (_generated.any(relPath.endsWith)) continue;
      if (excludeGlobs.any((g) => g.matches(relPath))) continue;
      sources[relPath] = entity.readAsStringSync();
    }
  }
  return extractFromSources(
    sources,
    globalRename: readGlobalFieldRename(root) ?? FieldRename.none,
  );
}

const _generated = [
  '.g.dart',
  '.freezed.dart',
  '.gr.dart',
  '.mocks.dart',
  '.config.dart',
];

/// Reads `field_rename` from the `json_serializable` builder options in
/// `<root>/build.yaml`.
FieldRename? readGlobalFieldRename(String root) {
  final file = File(p.join(root, 'build.yaml'));
  if (!file.existsSync()) return null;
  final Object? doc;
  try {
    doc = loadYaml(file.readAsStringSync());
  } on YamlException {
    return null;
  }
  if (doc is! Map) return null;
  final targets = doc['targets'];
  if (targets is! Map) return null;
  for (final target in targets.values) {
    if (target is! Map) continue;
    final builders = target['builders'];
    if (builders is! Map) continue;
    for (final entry in builders.entries) {
      if (!entry.key.toString().contains('json_serializable')) continue;
      final builder = entry.value;
      if (builder is! Map) continue;
      final options = builder['options'];
      if (options is! Map) continue;
      final rename = FieldRename.tryParse(options['field_rename']?.toString());
      if (rename != null) return rename;
    }
  }
  return null;
}

/// Extracts models from in-memory sources keyed by relative path.
DartProject extractFromSources(
  Map<String, String> sources, {
  FieldRename globalRename = FieldRename.none,
}) {
  final units = <String, (CompilationUnit, LineInfo)>{};
  for (final e in sources.entries) {
    final result = parseString(
      content: e.value,
      path: e.key,
      throwIfDiagnostics: false,
    );
    units[e.key] = (result.unit, result.lineInfo);
  }

  // Pass 1: enums and the names of every class with a fromJson.
  final enums = <String, DartEnum>{};
  final modelNames = <String>{};
  for (final e in units.entries) {
    final (unit, lines) = e.value;
    for (final decl in unit.declarations) {
      if (decl is EnumDeclaration) {
        final en = _extractEnum(decl, e.key, lines);
        enums[en.name] = en;
      } else if (decl is ClassDeclaration && _isJsonClass(decl)) {
        modelNames.add(decl.namePart.typeName.lexeme);
      }
    }
  }

  // Pass 2: models.
  final models = <String, DartModel>{};
  for (final e in units.entries) {
    final (unit, lines) = e.value;
    for (final decl in unit.declarations) {
      if (decl is! ClassDeclaration || !_isJsonClass(decl)) continue;
      final model = _extractModel(
        decl,
        file: e.key,
        lines: lines,
        globalRename: globalRename,
        modelNames: modelNames,
        enums: enums,
      );
      if (model != null) models[model.name] = model;
    }
  }
  return DartProject(models: models, enums: enums);
}

bool _isJsonClass(ClassDeclaration decl) =>
    _fromJsonMembers(decl).isNotEmpty ||
    annotation(decl.metadata, const {'JsonSerializable'}) != null;

List<ClassMember> _fromJsonMembers(ClassDeclaration decl) => [
  for (final m in decl.body.members)
    if ((m is ConstructorDeclaration &&
            const {'fromJson', 'fromMap'}.contains(m.name?.lexeme)) ||
        (m is MethodDeclaration &&
            m.isStatic &&
            const {'fromJson', 'fromMap'}.contains(m.name.lexeme)))
      m,
];

DartModel? _extractModel(
  ClassDeclaration decl, {
  required String file,
  required LineInfo lines,
  required FieldRename globalRename,
  required Set<String> modelNames,
  required Map<String, DartEnum> enums,
}) {
  final name = decl.namePart.typeName.lexeme;
  final line = lines.getLocation(decl.namePart.offset).lineNumber;
  final jsonSerializable = annotation(decl.metadata, const {
    'JsonSerializable',
  });
  final freezed = annotation(decl.metadata, const {'freezed', 'Freezed'});
  final fromJson = _fromJsonMembers(decl);
  final generated = fromJson.any((m) => m.toSource().contains(r'_$'));

  if (freezed != null) {
    if (fromJson.isEmpty) return null;
    return DartModel(
      name: name,
      file: file,
      line: line,
      kind: ModelKind.freezed,
      reads: _freezedReads(decl, lines, globalRename),
    );
  }
  final createFactory = jsonSerializable == null
      ? null
      : namedArg(jsonSerializable, 'createFactory')?.toSource();
  if ((jsonSerializable != null && createFactory != 'false') || generated) {
    return DartModel(
      name: name,
      file: file,
      line: line,
      kind: ModelKind.jsonSerializable,
      reads: _jsonSerializableReads(decl, lines, globalRename),
    );
  }
  if (fromJson.isEmpty) return null;
  return DartModel(
    name: name,
    file: file,
    line: line,
    kind: ModelKind.handWritten,
    reads: HandWrittenAnalyzer(
      decl: decl,
      lines: lines,
      modelNames: modelNames,
      enums: enums,
    ).analyze(fromJson),
  );
}

FieldRename _classRename(
  NodeList<Annotation> metadata,
  FieldRename globalRename,
) {
  final js = annotation(metadata, const {'JsonSerializable'});
  final raw = js == null ? null : namedArg(js, 'fieldRename')?.toSource();
  return FieldRename.tryParse(raw) ?? globalRename;
}

List<FieldRead> _jsonSerializableReads(
  ClassDeclaration decl,
  LineInfo lines,
  FieldRename globalRename,
) {
  final rename = _classRename(decl.metadata, globalRename);
  final classConverters = _hasClassConverters(decl.metadata);

  // Constructor defaults: `this.count = 0`.
  final ctorDefaults = <String>{};
  for (final m in decl.body.members) {
    if (m is ConstructorDeclaration && m.factoryKeyword == null) {
      for (final param in m.parameters.parameters) {
        if (param.defaultClause != null && param.name != null) {
          ctorDefaults.add(param.name!.lexeme);
        }
      }
    }
  }

  final reads = <FieldRead>[];
  for (final m in decl.body.members) {
    if (m is! FieldDeclaration || m.isStatic) continue;
    final jsonKey = annotation(m.metadata, const {'JsonKey'});
    if (_ignored(jsonKey)) continue;
    for (final v in m.fields.variables) {
      if (m.fields.isFinal && v.initializer != null) continue;
      if (m.fields.isConst) continue;
      final field = v.name.lexeme;
      final typeSource = m.fields.type?.toSource() ?? 'dynamic';
      reads.add(
        _generatedRead(
          field: field,
          type: DartType.parse(typeSource),
          jsonKey: jsonKey,
          rename: rename,
          hasDefault: ctorDefaults.contains(field),
          converter: classConverters || _hasConverter(m.metadata),
          line: lines.getLocation(v.name.offset).lineNumber,
        ),
      );
    }
  }
  return reads;
}

List<FieldRead> _freezedReads(
  ClassDeclaration decl,
  LineInfo lines,
  FieldRename globalRename,
) {
  final factories = [
    for (final m in decl.body.members)
      if (m is ConstructorDeclaration &&
          m.factoryKeyword != null &&
          m.redirectedConstructor != null)
        m,
  ];
  final unnamed = factories.where((f) => f.name == null).toList();
  final chosen = unnamed.isNotEmpty ? unnamed : factories;
  final classConverters = _hasClassConverters(decl.metadata);

  final byKey = <String, FieldRead>{};
  for (final ctor in chosen) {
    final rename = _classRename(
      ctor.metadata,
      _classRename(decl.metadata, globalRename),
    );
    for (final param in ctor.parameters.parameters) {
      final field = param.name?.lexeme;
      if (field == null) continue;
      final jsonKey = annotation(param.metadata, const {'JsonKey'});
      if (_ignored(jsonKey)) continue;
      final read = _generatedRead(
        field: field,
        type: DartType.parse(param.type?.toSource() ?? 'dynamic'),
        jsonKey: jsonKey,
        rename: rename,
        hasDefault:
            annotation(param.metadata, const {'Default'}) != null ||
            param.defaultClause != null,
        converter:
            classConverters ||
            _hasConverter(param.metadata) ||
            _hasClassConverters(ctor.metadata),
        line: lines.getLocation(param.name!.offset).lineNumber,
      );
      byKey.putIfAbsent(read.key, () => read);
    }
  }
  return byKey.values.toList();
}

FieldRead _generatedRead({
  required String field,
  required DartType type,
  required Annotation? jsonKey,
  required FieldRename rename,
  required bool hasDefault,
  required bool converter,
  required int line,
}) {
  final explicitName = jsonKey == null
      ? null
      : stringValue(namedArg(jsonKey, 'name'));
  final withDefault =
      hasDefault ||
      (jsonKey != null && namedArg(jsonKey, 'defaultValue') != null);
  final customFromJson =
      jsonKey != null && namedArg(jsonKey, 'fromJson') != null;
  final unknownEnum = jsonKey == null
      ? null
      : namedArg(jsonKey, 'unknownEnumValue');
  return FieldRead(
    key: explicitName ?? rename.apply(field),
    fieldName: field,
    type: type,
    nullSafe: type.acceptsNull || withDefault || customFromJson,
    hasDefault: withDefault,
    customConverter: converter || customFromJson,
    enumFallback: unknownEnum != null,
    line: line,
  );
}

bool _ignored(Annotation? jsonKey) {
  if (jsonKey == null) return false;
  return namedArg(jsonKey, 'ignore')?.toSource() == 'true' ||
      namedArg(jsonKey, 'includeFromJson')?.toSource() == 'false';
}

/// Field-level converters like `@EpochDateTimeConverter()`.
bool _hasConverter(NodeList<Annotation> metadata) =>
    metadata.any((a) => _annotationName(a).endsWith('Converter'));

bool _hasClassConverters(NodeList<Annotation> metadata) {
  final js = annotation(metadata, const {'JsonSerializable'});
  return (js != null && namedArg(js, 'converters') != null) ||
      _hasConverter(metadata);
}

DartEnum _extractEnum(EnumDeclaration decl, String file, LineInfo lines) {
  final name = decl.namePart.typeName.lexeme;
  final jsonEnum = annotation(decl.metadata, const {'JsonEnum'});
  final rename =
      FieldRename.tryParse(
        jsonEnum == null ? null : namedArg(jsonEnum, 'fieldRename')?.toSource(),
      ) ??
      FieldRename.none;
  final valueField = jsonEnum == null
      ? null
      : stringValue(namedArg(jsonEnum, 'valueField'));

  // Position of `valueField` in the enum's generative constructor.
  int? valueIndex;
  if (valueField != null) {
    for (final m in decl.body.members) {
      if (m is ConstructorDeclaration && m.factoryKeyword == null) {
        final params = m.parameters.parameters
            .where((x) => x.isPositional)
            .toList();
        final i = params.indexWhere((x) => x.name?.lexeme == valueField);
        if (i >= 0) valueIndex = i;
      }
    }
  }

  final switchLiterals = <String>[];
  var safeParse = false;
  for (final m in decl.body.members) {
    final collector = _CaseLiteralCollector();
    m.accept(collector);
    switchLiterals.addAll(collector.literals);
    final src = m.toSource();
    if (m is MethodDeclaration || m is ConstructorDeclaration) {
      if (RegExp(r'orElse|\?\?|default|_ =>|OrNull|tryByName').hasMatch(src)) {
        safeParse = true;
      }
    }
  }

  final hasJsonValue = decl.body.constants.any(
    (c) => annotation(c.metadata, const {'JsonValue'}) != null,
  );
  final firstArgs = [
    for (final c in decl.body.constants)
      c.arguments?.argumentList.arguments.firstOrNull,
  ];
  final allStringArgs =
      firstArgs.isNotEmpty && firstArgs.every((a) => a is SimpleStringLiteral);

  final values = <Object?>[];
  for (final c in decl.body.constants) {
    final jsonValue = annotation(c.metadata, const {'JsonValue'});
    final positional = c.arguments?.argumentList.arguments
        .whereType<Expression>()
        .toList();
    if (jsonValue != null) {
      values.add(
        literalValue(
          jsonValue.arguments?.arguments.whereType<Expression>().firstOrNull,
        ),
      );
    } else if (valueIndex != null &&
        positional != null &&
        valueIndex < positional.length) {
      values.add(literalValue(positional[valueIndex]));
    } else if (!hasJsonValue && valueField == null && jsonEnum == null) {
      // Hand-written: prefer literals the parser switches on, then string
      // constructor arguments, then names.
      if (switchLiterals.isNotEmpty) continue;
      values.add(
        allStringArgs
            ? (firstArgs[decl.body.constants.indexOf(c)]!
                      as SimpleStringLiteral)
                  .value
            : c.name.lexeme,
      );
    } else {
      values.add(rename.apply(c.name.lexeme));
    }
  }
  if (!hasJsonValue &&
      valueField == null &&
      jsonEnum == null &&
      switchLiterals.isNotEmpty) {
    values
      ..clear()
      ..addAll(switchLiterals.toSet());
  }
  return DartEnum(
    name: name,
    file: file,
    line: lines.getLocation(decl.namePart.offset).lineNumber,
    values: values,
    safeParse: safeParse,
  );
}

class _CaseLiteralCollector extends RecursiveAstVisitor<void> {
  final literals = <String>[];

  @override
  void visitConstantPattern(ConstantPattern node) {
    final e = node.expression;
    if (e is SimpleStringLiteral) literals.add(e.value);
    super.visitConstantPattern(node);
  }
}

/// First annotation whose (unprefixed) name is in [names].
Annotation? annotation(NodeList<Annotation> metadata, Set<String> names) {
  for (final a in metadata) {
    if (names.contains(_annotationName(a))) return a;
  }
  return null;
}

String _annotationName(Annotation a) => a.name.toSource().split('.').last;

/// Named argument [name] of an annotation, e.g. `@JsonKey(name: 'x')`.
Expression? namedArg(Annotation a, String name) {
  for (final arg in a.arguments?.arguments ?? const <Argument>[]) {
    if (arg is NamedArgument && arg.name.lexeme == name) {
      return arg.argumentExpression;
    }
  }
  return null;
}

/// The value of a string literal expression, or `null`.
String? stringValue(Expression? e) => e is StringLiteral ? e.stringValue : null;

/// The value of a string/int/double/bool literal (else its source).
Object? literalValue(Expression? e) => switch (e) {
  null => null,
  StringLiteral() => e.stringValue,
  IntegerLiteral() => e.value,
  DoubleLiteral() => e.value,
  BooleanLiteral() => e.value,
  PrefixExpression(operator: final op, operand: IntegerLiteral(:final value))
      when op.lexeme == '-' && value != null =>
    -value,
  _ => e.toSource(),
};
