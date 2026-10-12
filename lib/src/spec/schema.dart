/// A normalized, version-agnostic view of an OpenAPI 3.x / Swagger 2.0
/// document: only what the drift checks need.
library;

/// The JSON type a schema node accepts.
enum JsonType { string, integer, number, boolean, array, object, any }

/// One schema node. `$ref`s are kept as names and resolved lazily through
/// [ApiSpec.resolve], so recursive schemas (a `Category` with a parent
/// `Category`) are fine.
class SchemaNode {
  const SchemaNode({
    this.type = JsonType.any,
    this.format,
    this.nullable = false,
    this.ref,
    this.items,
    this.properties = const {},
    this.required = const {},
    this.enumValues,
    this.allOf = const [],
    this.isUnion = false,
  });

  final JsonType type;
  final String? format;

  /// `nullable: true` (3.0), `type: [x, 'null']` (3.1), `x-nullable` (2.0) or
  /// a `oneOf`/`anyOf` that includes `null`.
  final bool nullable;

  /// Name of the referenced schema when this node is (or wraps) a `$ref`.
  final String? ref;

  /// Item schema for arrays.
  final SchemaNode? items;
  final Map<String, SchemaNode> properties;
  final Set<String> required;
  final List<Object?>? enumValues;

  /// `allOf` members, merged by [ApiSpec.resolve].
  final List<SchemaNode> allOf;

  /// A real `oneOf`/`anyOf` between several non-null shapes: the type is not
  /// statically known, so type checks are skipped.
  final bool isUnion;

  SchemaNode copyWith({bool? nullable}) => SchemaNode(
    type: type,
    format: format,
    nullable: nullable ?? this.nullable,
    ref: ref,
    items: items,
    properties: properties,
    required: required,
    enumValues: enumValues,
    allOf: allOf,
    isUnion: isUnion,
  );

  /// Short human description, e.g. `integer(int64)`, `array<Pet>`, `Pet`.
  String describe() {
    if (ref != null) return ref!;
    if (isUnion) return 'oneOf';
    final base = switch (type) {
      JsonType.array => 'array<${items?.describe() ?? 'any'}>',
      JsonType.any => 'any',
      _ => type.name,
    };
    return format == null ? base : '$base($format)';
  }
}

/// A parsed API description.
class ApiSpec {
  ApiSpec({
    required this.label,
    required this.schemas,
    required this.responses,
  });

  /// Builds an [ApiSpec] from a decoded JSON/YAML document.
  factory ApiSpec.fromDocument(Map<String, Object?> doc) {
    final swagger = doc['swagger']?.toString();
    final openapi = doc['openapi']?.toString();
    if (swagger == null && openapi == null) {
      throw const FormatException(
        'Not an OpenAPI/Swagger document: no "openapi" or "swagger" field.',
      );
    }
    final isV2 = swagger != null;
    final rawSchemas = isV2
        ? _map(doc['definitions'])
        : _map(_map(doc['components'])['schemas']);
    final schemas = <String, SchemaNode>{
      for (final e in rawSchemas.entries) e.key: parseSchema(e.value),
    };

    final responses = <String, SchemaNode>{};
    final sharedResponses = isV2
        ? _map(doc['responses'])
        : _map(_map(doc['components'])['responses']);
    for (final pathEntry in _map(doc['paths']).entries) {
      for (final opEntry in _map(pathEntry.value).entries) {
        final method = opEntry.key.toUpperCase();
        if (!_httpMethods.contains(method)) continue;
        final op = _map(opEntry.value);
        final schema = _successSchema(_map(op['responses']), sharedResponses);
        if (schema != null) {
          responses['$method ${pathEntry.key}'] = parseSchema(schema);
        }
      }
    }
    return ApiSpec(
      label: isV2 ? 'Swagger $swagger' : 'OpenAPI $openapi',
      schemas: schemas,
      responses: responses,
    );
  }

  /// e.g. `OpenAPI 3.0.2` or `Swagger 2.0`.
  final String label;

  /// Named schemas (`components.schemas` / `definitions`).
  final Map<String, SchemaNode> schemas;

  /// Success-response body schema per operation, keyed `GET /pet/{petId}`.
  final Map<String, SchemaNode> responses;

  static const _httpMethods = {
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
  };

  /// Follows `$ref`s and merges `allOf`, returning a concrete node. The
  /// nullability of the original node is kept.
  SchemaNode resolve(SchemaNode node) => _resolve(node, <String>{});

  SchemaNode _resolve(SchemaNode node, Set<String> seen) {
    var current = node;
    if (current.ref != null && current.allOf.isEmpty) {
      final name = current.ref!;
      final target = schemas[name];
      if (target == null || !seen.add(name)) return current;
      final resolved = _resolve(target, seen);
      return SchemaNode(
        type: resolved.type,
        format: resolved.format,
        nullable: node.nullable || resolved.nullable,
        ref: name,
        items: resolved.items,
        properties: resolved.properties,
        required: resolved.required,
        enumValues: resolved.enumValues,
        isUnion: resolved.isUnion,
      );
    }
    if (current.allOf.isEmpty) return current;

    final properties = <String, SchemaNode>{};
    final required = <String>{};
    List<Object?>? enumValues = current.enumValues;
    var type = current.type;
    String? format = current.format;
    var nullable = current.nullable;
    for (final part in current.allOf) {
      final r = _resolve(part, {...seen});
      properties.addAll(r.properties);
      required.addAll(r.required);
      enumValues ??= r.enumValues;
      if (type == JsonType.any) type = r.type;
      format ??= r.format;
      nullable = nullable || r.nullable;
    }
    properties.addAll(current.properties);
    required.addAll(current.required);
    // A single-member allOf is the 3.0 idiom for "a nullable $ref".
    final singleRef = current.allOf.length == 1
        ? current.allOf.first.ref
        : null;
    current = SchemaNode(
      type: properties.isNotEmpty ? JsonType.object : type,
      format: format,
      nullable: nullable,
      ref: current.ref ?? singleRef,
      properties: properties,
      required: required,
      enumValues: enumValues,
    );
    return current;
  }
}

/// Parses one raw schema object (no `$ref` following).
SchemaNode parseSchema(Object? raw) {
  final m = _map(raw);
  if (m.isEmpty) return const SchemaNode();

  final refValue = m[r'$ref'];
  if (refValue is String) {
    return SchemaNode(
      ref: refName(refValue),
      nullable: m['nullable'] == true || m['x-nullable'] == true,
    );
  }

  var nullable = m['nullable'] == true || m['x-nullable'] == true;

  // oneOf / anyOf: strip `null` members; one remaining member = that member.
  for (final key in const ['oneOf', 'anyOf']) {
    final members = m[key];
    if (members is! List) continue;
    final nonNull = <Object?>[];
    for (final member in members) {
      final mm = _map(member);
      if (mm['type'] == 'null' ||
          (mm['enum'] is List &&
              (mm['enum'] as List).every((v) => v == null))) {
        nullable = true;
      } else {
        nonNull.add(member);
      }
    }
    if (nonNull.length == 1) {
      final inner = parseSchema(nonNull.single);
      return inner.copyWith(nullable: inner.nullable || nullable);
    }
    return SchemaNode(nullable: nullable, isUnion: true);
  }

  var type = JsonType.any;
  final rawType = m['type'];
  if (rawType is String) {
    type = _jsonType(rawType);
  } else if (rawType is List) {
    final names = rawType.map((t) => t.toString()).toList();
    if (names.remove('null')) nullable = true;
    if (names.length == 1) type = _jsonType(names.single);
  }

  final allOfRaw = m['allOf'];
  final allOf = allOfRaw is List
      ? allOfRaw.map(parseSchema).toList()
      : const <SchemaNode>[];

  final props = _map(m['properties']);
  if (type == JsonType.any && (props.isNotEmpty || allOf.isNotEmpty)) {
    type = JsonType.object;
  }
  if (type == JsonType.any && m['items'] != null) type = JsonType.array;

  final requiredRaw = m['required'];
  final enumRaw = m['enum'];
  List<Object?>? enumValues;
  if (enumRaw is List) {
    enumValues = enumRaw.where((v) => v != null).toList();
    if (enumRaw.contains(null)) nullable = true;
  }

  return SchemaNode(
    type: type,
    format: m['format']?.toString(),
    nullable: nullable,
    items: m['items'] == null ? null : parseSchema(m['items']),
    properties: {for (final e in props.entries) e.key: parseSchema(e.value)},
    required: requiredRaw is List
        ? requiredRaw.map((e) => e.toString()).toSet()
        : const {},
    enumValues: enumValues,
    allOf: allOf,
  );
}

/// `#/components/schemas/Pet` -> `Pet`.
String refName(String ref) {
  var last = ref.split('/').last;
  last = last.replaceAll('~1', '/').replaceAll('~0', '~');
  if (last.endsWith('.json') || last.endsWith('.yaml')) {
    last = last.substring(0, last.lastIndexOf('.'));
  }
  return Uri.decodeComponent(last);
}

Object? _successSchema(
  Map<String, Object?> responses,
  Map<String, Object?> shared,
) {
  final codes = responses.keys.toList()..sort();
  final ordered = [
    ...codes.where((c) => c.startsWith('2')),
    if (responses.containsKey('default')) 'default',
  ];
  for (final code in ordered) {
    var response = _map(responses[code]);
    final ref = response[r'$ref'];
    if (ref is String) response = _map(shared[refName(ref)]);
    if (response['schema'] != null) return response['schema']; // Swagger 2
    final content = _map(response['content']);
    final jsonKey = content.keys.firstWhere(
      (k) => k.contains('json'),
      orElse: () => content.keys.isEmpty ? '' : content.keys.first,
    );
    final schema = _map(content[jsonKey])['schema'];
    if (schema != null) return schema;
  }
  return null;
}

JsonType _jsonType(String name) => switch (name) {
  'string' => JsonType.string,
  'integer' => JsonType.integer,
  'number' => JsonType.number,
  'boolean' => JsonType.boolean,
  'array' => JsonType.array,
  'object' => JsonType.object,
  _ => JsonType.any,
};

Map<String, Object?> _map(Object? raw) {
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) return raw.map((k, v) => MapEntry(k.toString(), v));
  return const {};
}
