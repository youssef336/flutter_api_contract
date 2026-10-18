# Changelog

## 0.1.1

Fewer false positives on generated (NestJS) specs.

- A bare `{"type": "object"}` (no `properties`, `additionalProperties`, `$ref` or composition),
  which `@nestjs/swagger` emits for `string | null` and unknown types, is now "any": never a
  `type-mismatch`.
- Enums whose own parser ends in a default constant (`raw == 'A' ? E.a : E.b`, a final
  `return E.b;`) count as having a fallback, and parsers that upper/lower-case the input match
  schema values case-insensitively. `enum-unhandled` with a fallback is now info, not warning.
- Reads guarded by a check on the same key (`json['x'] is Map ? ... : json['x'] as String?`,
  `json['x'] != null && ...`, `if (json['x'] is Map) {...}`) no longer report
  `nullable-mismatch` / `type-mismatch`, including the implicit parent-map reads.
- Pairing: schemas only used as request bodies are never matched to a model; `XResponse`
  prefers `XResponseDto` over `XDto`; a name match covering under half of a model's keys is
  replaced by a schema holding at least 90% of them, else its missing keys drop to info.
  New info finding `ambiguous-match` explains either case.

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
