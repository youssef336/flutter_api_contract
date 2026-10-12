/// What the extractor learns about the app's Dart models.
library;

/// How a model is deserialized.
enum ModelKind {
  /// A hand-written `fromJson` reading `json['key']`.
  handWritten,

  /// `@JsonSerializable` + generated `_$XFromJson`.
  jsonSerializable,

  /// `@freezed` with a `fromJson` factory.
  freezed,
}

/// A Dart type as written in source, e.g. `List<Pet>?`.
class DartType {
  const DartType(this.name, {this.nullable = false, this.args = const []});

  /// Parses source text such as `Map<String, dynamic>?` or `List<Pet?>`.
  factory DartType.parse(String source) {
    final parser = _TypeParser(source.replaceAll(RegExp(r'\s+'), ''));
    return parser.parse();
  }

  /// Base name without import prefix, e.g. `List`, `int`, `Pet`.
  final String name;
  final bool nullable;
  final List<DartType> args;

  /// `dynamic`, `Object?`, `Object`, `var` and unresolvable types accept any
  /// JSON value.
  bool get isDynamic => name == 'dynamic' || name == 'Object' || name == '';

  bool get acceptsNull => nullable || name == 'dynamic' || name == 'Null';

  DartType withNullable(bool value) =>
      DartType(name, nullable: value, args: args);

  @override
  String toString() {
    final generic = args.isEmpty ? '' : '<${args.join(', ')}>';
    return '$name$generic${nullable ? '?' : ''}';
  }
}

class _TypeParser {
  _TypeParser(this.s);
  final String s;
  var i = 0;

  DartType parse() {
    final start = i;
    while (i < s.length && !'<>,?'.contains(s[i])) {
      i++;
    }
    var name = s.substring(start, i);
    if (name.contains('.')) name = name.substring(name.lastIndexOf('.') + 1);
    final args = <DartType>[];
    if (i < s.length && s[i] == '<') {
      i++;
      while (i < s.length) {
        args.add(parse());
        if (i < s.length && s[i] == ',') {
          i++;
          continue;
        }
        if (i < s.length && s[i] == '>') i++;
        break;
      }
    }
    var nullable = false;
    if (i < s.length && s[i] == '?') {
      nullable = true;
      i++;
    }
    return DartType(name, nullable: nullable, args: args);
  }
}

/// One JSON key a model reads.
class FieldRead {
  FieldRead({
    required this.key,
    required this.line,
    this.path = const [],
    this.fieldName,
    this.type,
    this.nullSafe = true,
    this.hasDefault = false,
    this.customConverter = false,
    this.enumFallback = false,
    this.enumName,
  });

  /// Top-level JSON key, e.g. `user_name`.
  final String key;

  /// Nested keys read below [key], e.g. `json['a']['b']` -> `['b']`.
  final List<String> path;

  /// Dart field/parameter the value lands in, when known.
  final String? fieldName;

  /// Dart type the JSON value must have; `null` when unknown.
  DartType? type;

  /// `true` when a missing key or `null` value cannot throw.
  bool nullSafe;

  /// A default kicks in for missing/null (`??`, `@Default`, `defaultValue`).
  bool hasDefault;

  /// Value goes through a custom converter: type checks are skipped.
  bool customConverter;

  /// Unknown enum values fall back instead of throwing.
  bool enumFallback;

  /// Enum parsed by an explicit `X.values.byName` / `X.fromJson` call.
  String? enumName;

  final int line;

  /// `a.b.c` for display and fingerprints.
  String get displayKey => [key, ...path].join('.');
}

/// A class that is deserialized from JSON.
class DartModel {
  DartModel({
    required this.name,
    required this.file,
    required this.line,
    required this.kind,
    required this.reads,
  });

  final String name;

  /// Path relative to the project root.
  final String file;
  final int line;
  final ModelKind kind;
  final List<FieldRead> reads;
}

/// An enum used by models.
class DartEnum {
  DartEnum({
    required this.name,
    required this.file,
    required this.line,
    required this.values,
    this.safeParse = false,
  });

  final String name;
  final String file;
  final int line;

  /// Wire values (`@JsonValue`, `valueField`, `case 'x':` or names).
  final List<Object?> values;

  /// Its own parser falls back on unknown input (`orElse`, `??`, `default:`).
  final bool safeParse;
}

/// Everything extracted from a Dart project.
class DartProject {
  DartProject({required this.models, required this.enums});

  final Map<String, DartModel> models;
  final Map<String, DartEnum> enums;
}
