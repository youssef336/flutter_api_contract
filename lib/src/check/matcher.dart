import '../config.dart';
import '../dart/models.dart';
import '../spec/schema.dart';

/// How a model was paired with a schema.
enum MatchVia { config, endpoint, name, suffix, shape }

/// A model paired with the schema it is checked against.
class ModelMatch {
  ModelMatch({
    required this.model,
    required this.schemaName,
    required this.schema,
    required this.via,
    this.note,
    this.lowOverlap = false,
  });

  final DartModel model;

  /// Schema name, or a label such as `GET /me#data` for inline schemas.
  final String schemaName;
  final SchemaNode schema;
  final MatchVia via;

  /// Why the pairing is uncertain or differs from the name, if it does.
  final String? note;

  /// The schema has few of the keys the model reads, and no other schema
  /// fits better: missing keys are more likely a wrong pairing than drift.
  final bool lowOverlap;
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

    final named = _byName(model, spec, config, byBase);
    if (named != null) {
      matches.add(_checkShape(model, named.$1, named.$2, spec, config));
      continue;
    }
    final requestOnly = _requestOnlyNamesake(model, spec, config, byBase);
    if (requestOnly != null) {
      final byShape = _bestByShape(model, spec, config, exclude: requestOnly);
      if (byShape != null) {
        matches.add(
          ModelMatch(
            model: model,
            schemaName: byShape.$1,
            schema: spec.schemas[byShape.$1]!,
            via: MatchVia.shape,
            note:
                'the name points at $requestOnly, which is only used as a '
                'request body; ${byShape.$1} has '
                '${(byShape.$2 * 100).round()}% of the keys '
                '${model.name} reads, so it is checked against ${byShape.$1}',
          ),
        );
        continue;
      }
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

/// The schema a model's name points at: exact, then a schema whose name
/// minus a suffix is the model's full name (`CreateVibeResponse` ->
/// `CreateVibeResponseDto`), then both sides stripped. Schemas only used as
/// request bodies are skipped: a `fromJson` model never decodes them.
(String, MatchVia)? _byName(
  DartModel model,
  ApiSpec spec,
  ContractConfig config,
  Map<String, List<String>> byBase,
) {
  if (spec.schemas.containsKey(model.name)) return (model.name, MatchVia.name);
  final full = model.name.toLowerCase();
  final base = _base(model.name, config.suffixes);
  for (final key in {full, base}) {
    final candidates = [
      for (final c in byBase[key] ?? const <String>[])
        if (!spec.isRequestOnly(c)) c,
    ];
    if (candidates.isEmpty) continue;
    int rank(String c) =>
        (spec.responseSchemas.contains(c) ? 0 : 2) +
        (c.toLowerCase() == key ? 0 : 1);
    // Prefer response schemas, then the bare name (`User` over `UserDto`).
    final sorted = [...candidates]..sort((a, b) => rank(a).compareTo(rank(b)));
    return (sorted.first, MatchVia.suffix);
  }
  return null;
}

/// Minimum number of reads before the key overlap is trusted.
const _minReadsForShape = 3;

/// A name match that shares under half of the model's keys is probably the
/// wrong schema (`LiveStatsModel` vs `LiveStatsDto` while `UserLiveStatsDto`
/// has exactly its fields). Re-pairs by shape when another schema clearly
/// fits, else marks the match as low-overlap.
ModelMatch _checkShape(
  DartModel model,
  String schemaName,
  MatchVia via,
  ApiSpec spec,
  ContractConfig config,
) {
  final paths = _readPaths(model, config);
  final named = ModelMatch(
    model: model,
    schemaName: schemaName,
    schema: spec.schemas[schemaName]!,
    via: via,
  );
  if (paths.length < _minReadsForShape) return named;
  final nameScore = _overlap(spec, spec.schemas[schemaName]!, paths);
  if (nameScore >= 0.5) return named;

  final alternative = _bestByShape(model, spec, config, exclude: schemaName);
  final percent = (nameScore * 100).round();
  if (alternative != null) {
    final (best, bestScore) = alternative;
    return ModelMatch(
      model: model,
      schemaName: best,
      schema: spec.schemas[best]!,
      via: MatchVia.shape,
      note:
          'the name points at $schemaName, which has only $percent% of the '
          'keys ${model.name} reads; $best has '
          '${(bestScore * 100).round()}%, so it is checked against $best',
    );
  }
  return ModelMatch(
    model: model,
    schemaName: schemaName,
    schema: named.schema,
    via: via,
    lowOverlap: true,
    note:
        '$schemaName has only $percent% of the keys ${model.name} reads; '
        'it may be the wrong schema (a wrapper, or a different DTO)',
  );
}

/// The key paths [model] reads, minus ignored ones.
List<List<String>> _readPaths(DartModel model, ContractConfig config) => {
  for (final r in model.reads)
    if (!config.ignore.contains('${model.name}.${r.key}') &&
        !config.ignore.contains('${model.name}.${r.displayKey}'))
      r.displayKey: [r.key, ...r.path],
}.values.toList();

/// The request-only schema [model]'s name points at, if that is all its
/// name matches.
String? _requestOnlyNamesake(
  DartModel model,
  ApiSpec spec,
  ContractConfig config,
  Map<String, List<String>> byBase,
) {
  for (final key in {
    model.name.toLowerCase(),
    _base(model.name, config.suffixes),
  }) {
    for (final c in byBase[key] ?? const <String>[]) {
      if (spec.isRequestOnly(c)) return c;
    }
  }
  return null;
}

/// The schema that holds (nearly) every key [model] reads: at least 90% of
/// them, response schemas first, then the tightest fit. `null` for models
/// with fewer than [_minReadsForShape] reads.
(String, double)? _bestByShape(
  DartModel model,
  ApiSpec spec,
  ContractConfig config, {
  required String exclude,
}) {
  final paths = _readPaths(model, config);
  if (paths.length < _minReadsForShape) return null;
  String? best;
  var bestScore = 0.0;
  var bestRank = 0;
  for (final e in spec.schemas.entries) {
    if (e.key == exclude || spec.isRequestOnly(e.key)) continue;
    final score = _overlap(spec, e.value, paths);
    if (score < 0.9 || score < bestScore) continue;
    final rank =
        (spec.responseSchemas.contains(e.key) ? 0 : 100000) +
        spec.resolve(e.value).properties.length;
    if (score > bestScore || rank < bestRank) {
      best = e.key;
      bestScore = score;
      bestRank = rank;
    }
  }
  return best == null ? null : (best, bestScore);
}

/// Share of [paths] that exist in [schema]. A path that runs into a
/// free-form object (no properties) before its end counts half: it may be
/// there, but nothing proves it.
double _overlap(ApiSpec spec, SchemaNode schema, List<List<String>> paths) {
  final root = spec.resolve(schema);
  if (root.properties.isEmpty) return 0;
  var found = 0.0;
  for (final path in paths) {
    var node = root;
    var credit = 1.0;
    for (final segment in path) {
      if (node.properties.isEmpty) {
        credit = 0.5;
        break;
      }
      final next = node.properties[segment];
      if (next == null) {
        credit = 0;
        break;
      }
      var resolved = spec.resolve(next);
      if (resolved.type == JsonType.array && resolved.items != null) {
        resolved = spec.resolve(resolved.items!);
      }
      node = resolved;
    }
    found += credit;
  }
  return found / paths.length;
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
