import '../config.dart';
import '../dart/models.dart';
import '../spec/schema.dart';

/// How a model was paired with a schema.
enum MatchVia { config, endpoint, name, suffix }

/// A model paired with the schema it is checked against.
class ModelMatch {
  ModelMatch({
    required this.model,
    required this.schemaName,
    required this.schema,
    required this.via,
  });

  final DartModel model;

  /// Schema name, or a label such as `GET /me#data` for inline schemas.
  final String schemaName;
  final SchemaNode schema;
  final MatchVia via;
}

/// Result of pairing every model with a schema.
class MatchResult {
  MatchResult({
    required this.matches,
    required this.unmatched,
    required this.skipped,
    required this.configErrors,
  });

  final List<ModelMatch> matches;

  /// Models with no schema, with the names that were tried.
  final Map<DartModel, List<String>> unmatched;

  /// Models switched off in config (`models: {X: null}` or `ignore: [X]`).
  final List<DartModel> skipped;

  /// `(model, message)` for config entries pointing nowhere.
  final List<(DartModel, String)> configErrors;
}

/// Pairs models with schemas: explicit `models:` mapping, then
/// `endpoints:`, then exact name, then name with suffixes stripped.
MatchResult matchModels(
  DartProject project,
  ApiSpec spec,
  ContractConfig config,
) {
  final matches = <ModelMatch>[];
  final unmatched = <DartModel, List<String>>{};
  final skipped = <DartModel>[];
  final configErrors = <(DartModel, String)>[];

  final byBase = <String, List<String>>{};
  for (final name in spec.schemas.keys) {
    byBase.putIfAbsent(_base(name, config.suffixes), () => []).add(name);
  }

  final models = project.models.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  for (final model in models) {
    if (config.ignore.contains(model.name)) {
      skipped.add(model);
      continue;
    }
    if (config.models.containsKey(model.name)) {
      final target = config.models[model.name];
      if (target == null) {
        skipped.add(model);
        continue;
      }
      final schema = spec.schemas[target];
      if (schema == null) {
        configErrors.add((
          model,
          'api_contract.yaml maps ${model.name} to "$target", '
              'but the spec has no schema with that name.',
        ));
      } else {
        matches.add(
          ModelMatch(
            model: model,
            schemaName: target,
            schema: schema,
            via: MatchVia.config,
          ),
        );
      }
      continue;
    }
    final endpoint = config.endpoints[model.name];
    if (endpoint != null) {
      final resolved = _endpointSchema(spec, endpoint);
      if (resolved == null) {
        configErrors.add((
          model,
          'api_contract.yaml maps ${model.name} to endpoint "$endpoint", '
              'but the spec has no JSON success response there.',
        ));
      } else {
        matches.add(
          ModelMatch(
            model: model,
            schemaName: resolved.$1,
            schema: resolved.$2,
            via: MatchVia.endpoint,
          ),
        );
      }
      continue;
    }

    final exact = spec.schemas[model.name];
    if (exact != null) {
      matches.add(
        ModelMatch(
          model: model,
          schemaName: model.name,
          schema: exact,
          via: MatchVia.name,
        ),
      );
      continue;
    }
    final base = _base(model.name, config.suffixes);
    final candidates = byBase[base] ?? const [];
    if (candidates.isNotEmpty) {
      // Prefer the bare name (`User`) over another suffixed one (`UserDto`).
      final pick = candidates.firstWhere(
        (c) => c.toLowerCase() == base,
        orElse: () => candidates.first,
      );
      matches.add(
        ModelMatch(
          model: model,
          schemaName: pick,
          schema: spec.schemas[pick]!,
          via: MatchVia.suffix,
        ),
      );
      continue;
    }
    unmatched[model] = {
      model.name,
      _stripOne(model.name, config.suffixes),
    }.toList();
  }
  return MatchResult(
    matches: matches,
    unmatched: unmatched,
    skipped: skipped,
    configErrors: configErrors,
  );
}

/// `GET /pet/{id}` or `GET /me#data` -> (label, schema node).
(String, SchemaNode)? _endpointSchema(ApiSpec spec, String endpoint) {
  final hash = endpoint.indexOf('#');
  final opKey = (hash < 0 ? endpoint : endpoint.substring(0, hash)).trim();
  final property = hash < 0 ? null : endpoint.substring(hash + 1).trim();
  final parts = opKey.split(RegExp(r'\s+'));
  if (parts.length != 2) return null;
  final key = '${parts[0].toUpperCase()} ${parts[1]}';
  var node = spec.responses[key];
  if (node == null) return null;

  SchemaNode unwrapArray(SchemaNode n) {
    final r = spec.resolve(n);
    return r.type == JsonType.array && r.items != null ? r.items! : n;
  }

  node = unwrapArray(node);
  if (property != null && property.isNotEmpty) {
    for (final segment in property.split('.')) {
      final next = spec.resolve(node!).properties[segment];
      if (next == null) return null;
      node = unwrapArray(next);
    }
  }
  final label = node!.ref ?? endpoint.trim();
  return (label, node);
}

String _stripOne(String name, List<String> suffixes) {
  final sorted = [...suffixes]..sort((a, b) => b.length.compareTo(a.length));
  for (final s in sorted) {
    if (name.length > s.length && name.endsWith(s)) {
      return name.substring(0, name.length - s.length);
    }
  }
  return name;
}

String _base(String name, List<String> suffixes) =>
    _stripOne(name, suffixes).toLowerCase();
