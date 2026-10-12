import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'schema.dart';

/// Thrown when the spec cannot be fetched or parsed.
class SpecException implements Exception {
  SpecException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Loads an OpenAPI/Swagger document from a local path or an http(s) URL.
///
/// [headers] are sent with URL requests (e.g. `Authorization`).
Future<ApiSpec> loadSpec(
  String source, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 30),
}) async {
  final text = await readSpecText(source, headers: headers, timeout: timeout);
  return parseSpecText(text, source: source);
}

/// Reads the raw text of a spec from a file or URL.
Future<String> readSpecText(
  String source, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 30),
}) async {
  final uri = Uri.tryParse(source);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json, */*');
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw SpecException(
          'Could not download the spec: HTTP ${response.statusCode} from $uri',
        );
      }
      return body;
    } on SocketException catch (e) {
      throw SpecException(
        'Could not download the spec from $uri: ${e.message}',
      );
    } on HandshakeException catch (e) {
      throw SpecException('TLS error while downloading $uri: ${e.message}');
    } on HttpException catch (e) {
      throw SpecException(
        'Could not download the spec from $uri: ${e.message}',
      );
    } on FormatException catch (e) {
      throw SpecException('Bad response from $uri: ${e.message}');
    } on Exception catch (e) {
      throw SpecException('Could not download the spec from $uri ($e)');
    } finally {
      client.close(force: true);
    }
  }
  final file = File(uri?.scheme == 'file' ? uri!.toFilePath() : source);
  if (!file.existsSync()) {
    throw SpecException('Spec file not found: $source');
  }
  return file.readAsStringSync();
}

/// Parses spec text (JSON or YAML) into an [ApiSpec].
ApiSpec parseSpecText(String text, {String source = '<spec>'}) {
  final Object? decoded;
  try {
    decoded = text.trimLeft().startsWith('{')
        ? jsonDecode(text)
        : yamlToPlain(loadYaml(text));
  } on YamlException catch (e) {
    throw SpecException('Could not parse $source as YAML: ${e.message}');
  } on FormatException catch (e) {
    throw SpecException('Could not parse $source as JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw SpecException('$source is not an OpenAPI/Swagger object.');
  }
  try {
    return ApiSpec.fromDocument(
      decoded.map((k, v) => MapEntry(k.toString(), v)),
    );
  } on FormatException catch (e) {
    throw SpecException('$source: ${e.message}');
  }
}

/// Converts `package:yaml` nodes into plain maps/lists/scalars.
Object? yamlToPlain(Object? node) {
  if (node is YamlMap || node is Map) {
    return {
      for (final e in (node as Map).entries)
        e.key.toString(): yamlToPlain(e.value),
    };
  }
  if (node is YamlList || node is List) {
    return [for (final v in node as List) yamlToPlain(v)];
  }
  return node;
}
