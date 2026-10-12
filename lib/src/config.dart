import 'dart:io';

import 'package:yaml/yaml.dart';

/// Thrown for an invalid `api_contract.yaml`.
class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Settings from `api_contract.yaml`. Every field is optional.
///
/// ```yaml
/// spec: https://api.example.com/docs-json
/// paths: [lib]
/// exclude: ['lib/legacy/**']
/// suffixes: [Model, Dto, Entity]
/// models:
///   WalletModel: WalletResponse   # explicit schema
///   DraftModel: null              # local only, never checked
/// endpoints:
///   ProfileModel: GET /me#data    # schema of a response (or a property)
/// ignore:
///   - UserModel.legacyField       # one key
///   - AnalyticsEvent              # whole model
/// headers:
///   Authorization: Bearer xyz
/// baseline: api_contract_baseline.json
/// ```
class ContractConfig {
  ContractConfig({
    this.spec,
    this.paths = const ['lib'],
    this.exclude = const [],
    this.suffixes = defaultSuffixes,
    this.models = const {},
    this.endpoints = const {},
    this.ignore = const {},
    this.headers = const {},
    this.baseline,
  });

  /// Parses YAML text.
  factory ContractConfig.parse(String text, {String source = 'config'}) {
    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw ConfigException('$source: ${e.message}');
    }
    if (doc == null) return ContractConfig();
    if (doc is! Map) throw ConfigException('$source must be a YAML map.');
    final yaml = doc;

    List<String> list(String key, List<String> fallback) {
      final v = yaml[key];
      if (v == null) return fallback;
      if (v is String) return [v];
      if (v is List) return [for (final e in v) e.toString()];
      throw ConfigException('$source: "$key" must be a list.');
    }

    Map<String, String?> map(String key) {
      final v = yaml[key];
      if (v == null) return const {};
      if (v is! Map) throw ConfigException('$source: "$key" must be a map.');
      return {
        for (final e in v.entries)
          e.key.toString(): switch (e.value) {
            null || false => null,
            final Object o when o.toString() == '-' => null,
            final Object o => o.toString(),
          },
      };
    }

    return ContractConfig(
      spec: doc['spec']?.toString(),
      paths: list('paths', const ['lib']),
      exclude: list('exclude', const []),
      suffixes: list('suffixes', defaultSuffixes),
      models: map('models'),
      endpoints: {
        for (final e in map('endpoints').entries)
          if (e.value != null) e.key: e.value!,
      },
      ignore: list('ignore', const []).toSet(),
      headers: {
        for (final e in map('headers').entries)
          if (e.value != null) e.key: _expandEnv(e.value!),
      },
      baseline: doc['baseline']?.toString(),
    );
  }

  /// Loads [path]; returns defaults when the file does not exist and
  /// [optional] is set.
  static ContractConfig load(String path, {bool optional = true}) {
    final file = File(path);
    if (!file.existsSync()) {
      if (optional) return ContractConfig();
      throw ConfigException('Config file not found: $path');
    }
    return ContractConfig.parse(file.readAsStringSync(), source: path);
  }

  static const defaultSuffixes = [
    'Model',
    'Dto',
    'DTO',
    'Response',
    'Entity',
    'Data',
    'Json',
  ];

  final String? spec;
  final List<String> paths;
  final List<String> exclude;
  final List<String> suffixes;

  /// Model -> schema name; `null` means "do not check this model".
  final Map<String, String?> models;

  /// Model -> `METHOD /path` with an optional `#property` envelope.
  final Map<String, String> endpoints;

  /// `Model` or `Model.key` entries to skip.
  final Set<String> ignore;

  /// Extra HTTP headers for downloading the spec. `${ENV}` is expanded.
  final Map<String, String> headers;
  final String? baseline;
}

String _expandEnv(String value) => value.replaceAllMapped(
  RegExp(r'\$\{(\w+)\}'),
  (m) => Platform.environment[m.group(1)] ?? '',
);
