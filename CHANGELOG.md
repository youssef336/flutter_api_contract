# Changelog

## 0.1.0

First release.

- Reads OpenAPI 3.0 / 3.1 and Swagger 2.0 specs, JSON or YAML, from a file or a URL
  (with `--header` for protected docs).
- Reads Dart models with `package:analyzer`: hand-written `fromJson`
  (`json['key']`, casts, `??`, null guards, nested `json['a']['b']`, aliases, enums via
  `values.byName` / `firstWhere(orElse:)`), `json_serializable` (`@JsonKey`, class and
  `build.yaml` `field_rename`, constructor defaults, `unknownEnumValue`, converters) and
  `freezed` (`@Default`, `@JsonKey`, unions).
- Pairs models with schemas by name (suffixes stripped), by explicit mapping or by endpoint
  (`GET /me#data`).
- Findings: `missing-in-schema` (with a rename suggestion), `required-ignored`,
  `nullable-mismatch`, `type-mismatch`, `enum-unhandled`, `enum-extra`, `unmatched-model`,
  `unknown-schema`.
- Output as text, Markdown, JSON or GitHub annotations; exit code 1 on errors
  (`--fail-on`).
- Shrink-only baseline (`--baseline`, `--update-baseline`).
