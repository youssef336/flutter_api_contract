[العربية](README.ar.md)

<h1 align="center">Flutter API Contract</h1>

<p align="center">
  Catch drift between your Dart models and the backend's OpenAPI / Swagger schema before it crashes in production.
</p>

<p align="center">
  <a href="https://pub.dev/packages/flutter_api_contract"><img src="https://img.shields.io/pub/v/flutter_api_contract?style=for-the-badge&logo=dart&label=pub.dev" alt="pub.dev"/></a>
  <img src="https://img.shields.io/badge/Dart-CLI-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart CLI">
  <img src="https://img.shields.io/badge/Flutter-models-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/OpenAPI-3.0%20%7C%203.1-6BA539?style=for-the-badge&logo=openapiinitiative&logoColor=white" alt="OpenAPI 3">
  <img src="https://img.shields.io/badge/Swagger-2.0-85EA2D?style=for-the-badge&logo=swagger&logoColor=black" alt="Swagger 2.0">
  <img src="https://img.shields.io/badge/CI-GitHub%20Actions-2088FF?style=for-the-badge&logo=githubactions&logoColor=white" alt="GitHub Actions">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="MIT">
</p>

> **English summary.** `api_contract` is a Dart command-line tool that compares the JSON your
> Flutter app *expects* with the JSON the backend *documents*. It reads an OpenAPI 3.x or
> Swagger 2.0 spec (JSON or YAML, local file or URL such as `/docs-json`) and parses your Dart
> models with `package:analyzer`: hand-written `fromJson` (`json['key']`, `as T?`, `??`, null
> guards, nested `json['a']['b']`), `json_serializable` (`@JsonKey`, `fieldRename`, the global
> `field_rename` in `build.yaml`, `unknownEnumValue`) and `freezed` (`@Default`, `@JsonKey`).
> Models are paired with schemas by name (`UserModel`/`UserDto` ↔ `User`), by explicit mapping,
> or by endpoint (`GET /me#data`). It then reports keys the app reads that the schema does not
> have (with a "did you mean" rename hint), required fields the app ignores, **non-nullable Dart
> fields the schema allows to be missing or null (crash risk)**, type mismatches, enum values the
> app cannot parse, and models with no schema. Output is text, Markdown, JSON or GitHub
> annotations; the exit code is 1 on errors so it can gate CI, and a shrink-only baseline lets
> you adopt it on a project with existing drift.

The backend renamed a field, made it optional, or added a new enum value... and your app still
remembers the old shape. The result: `type 'Null' is not a subtype of type 'String'` in
production. This tool compares the models in your Dart code with the backend's OpenAPI / Swagger
spec, and tells you about the difference **before** it reaches the user.

## ✨ What it does

- 📄 **Reads the spec**: OpenAPI 3.0 and 3.1 and Swagger 2.0, JSON or YAML, from a file or a URL
  (`--spec https://api.example.com/docs-json`). It understands `$ref`, `allOf`, `nullable`,
  `type: [string, 'null']`, `x-nullable` and `anyOf` containing `null`.
- 🔍 **Reads the models from the code itself** (with `package:analyzer`, without running a build):
  - **Hand-written fromJson**: `json['key']`, `as String` / `as String?`, `??`,
    `json['x'] == null ? null : ...`, `json['a']['b']`, `final data = json['data']`,
    `DateTime.parse`, `X.fromJson(...)`, `Status.values.byName(...)` and
    `firstWhere(..., orElse: ...)`.
  - **json_serializable**: `@JsonKey(name:, defaultValue:, includeFromJson:, unknownEnumValue:)`,
    `fieldRename` on the class, the global `field_rename` in `build.yaml`, and the constructor
    default.
  - **freezed**: the factory params, `@Default`, `@JsonKey`, `@JsonSerializable` on the factory,
    and unions.
  - **enums**: `@JsonValue`, `@JsonEnum(fieldRename:, valueField:)`, and `case 'x':` in a
    hand-written parser.
- 🔗 **Pairs each model with its schema**: by name (`UserModel` / `UserDto` / `User` ↔
  `components.schemas.User` after stripping the suffixes), by an explicit mapping in
  `api_contract.yaml`, or by endpoint (`ProfileModel: GET /me#data`).
- 🚨 **Reports these differences**:

  | Code | Severity | Meaning |
  |---|---|---|
  | `nullable-mismatch` | 🔴 error | The schema says the field may be `null` or absent, and the code reads it as non-nullable with no default → **crash** |
  | `missing-in-schema` | 🔴 / 🟡 | The code reads a key that is not in the schema (probably renamed), and suggests the closest name: "did you mean `user_name`?" |
  | `type-mismatch` | 🔴 / 🟡 | `int` vs `string`, `List` vs `object`, `int` vs `number` (fractions), `as double` vs an integer |
  | `enum-unhandled` | 🔴 / 🟡 | The schema has an enum value your enum does not know. Error if there is no fallback, warning if there is |
  | `enum-extra` | 🔵 info | Your enum has values the schema never sends |
  | `required-ignored` | 🔵 info | A field is required in the schema and the code never reads it |
  | `unmatched-model` | 🟡 warning | A model has no schema; it tells you the schema closest to its name |
  | `unknown-schema` | 🔴 error | The config points to a schema or endpoint that does not exist |

- 📤 **4 output formats**: `text` (for the terminal), `markdown` (to put in a PR), `json`, and
  `github` (annotations next to the line in the PR).
- 🚦 **Fails the CI**: exit code `1` if there is an error (or a warning with `--fail-on warning`).
- 📉 **Shrink-only baseline**: if your project has existing drift, accept it once and move on.
  Any **new** difference shows up, and an old one, once fixed, is removed from the baseline and
  never comes back.

## 📦 Installation

Requires Dart 3.11 or newer (or a Flutter version that ships it).

```bash
dart pub global activate flutter_api_contract
```

Or inside the project as a dev dependency:

```yaml
dev_dependencies:
  flutter_api_contract: ^0.1.0
```

```bash
dart run flutter_api_contract:api_contract --spec openapi.json
```

## 🚀 Usage

```bash
# from the root of the Flutter project
api_contract --spec https://api.example.com/docs-json
api_contract --spec docs/openapi.yaml --format markdown > drift.md
api_contract --spec "$SPEC_URL" -H "Authorization: Bearer $DOCS_TOKEN" --format github
```

| Option | What it does |
|---|---|
| `-s, --spec` | The spec file or URL (overrides `spec:` in the config) |
| `-p, --project` | The project root (default `.`) |
| `-c, --config` | The config file (default `api_contract.yaml`) |
| `-f, --format` | `text` · `markdown` · `json` · `github` |
| `--fail-on` | `error` (default) · `warning` · `never` |
| `-b, --baseline` | A JSON file with the accepted differences |
| `--update-baseline` | Creates the baseline if it does not exist, or only shrinks it if it does |
| `-H, --header` | A header for downloading the spec (repeatable) |
| `--[no-]color` | ANSI colors |

Exit codes: `0` no problems · `1` differences at the `--fail-on` level · `2` an error in the
command or the spec.

## 🧪 What the output looks like

This is a real run against the [Swagger Petstore v3](https://petstore3.swagger.io/api/v3/openapi.json)
with a small app containing 3 intentional differences (in `test/fixtures/petstore_app`):

```text
$ api_contract --spec https://petstore3.swagger.io/api/v3/openapi.json
API contract check · OpenAPI 3.0.4 (https://petstore3.swagger.io/api/v3/openapi.json) · 6 schemas · 3 models

CategoryModel → Category  lib/models/category_model.dart
  error    nullable-mismatch  name  lib/models/category_model.dart:15
           "name" is not required in Category, but the app reads it as non-nullable `String` with no default (CRASH RISK).
           → make `name` nullable or give it a default (`??`, @Default, defaultValue)

OrderModel → Order  lib/models/order_model.dart
  error    enum-unhandled  status  lib/models/order_model.dart:16
           enum OrderStatus does not know "delivered" from the schema, and parsing an unknown value throws (CRASH RISK).
           → add the values, or a fallback (@JsonKey(unknownEnumValue: ...) / orElse:)

PetModel → Pet  lib/models/pet_model.dart
  error    missing-in-schema  photo_urls  lib/models/pet_model.dart:18
           "photo_urls" is read by the app but Pet has no "photo_urls", and the read throws when it is absent (CRASH RISK).
           → did you mean "photoUrls"? (likely a backend rename)
  info     required-ignored  photoUrls  lib/models/pet_model.dart:5
           "photoUrls" is required in Pet but PetModel never reads it.

3 errors · 0 warnings · 1 info
```

## ⚙️ Config (optional)

Put an `api_contract.yaml` in the project root (a complete copy is in `api_contract.example.yaml`):

```yaml
spec: https://api.example.com/docs-json
paths: [lib]
exclude: ['lib/legacy/**']
suffixes: [Model, Dto, DTO, Response, Entity, Data, Json]
models:
  WalletModel: WalletResponse   # the exact schema name
  DraftPost: null               # a local model, do not check it
endpoints:
  ProfileModel: GET /me#data    # the endpoint's response; #data unwraps the envelope
ignore:
  - AnalyticsEvent              # a whole model
  - UserModel.legacyField       # a single key
headers:
  Authorization: Bearer ${DOCS_TOKEN}
baseline: api_contract_baseline.json
```

## 📉 Baseline

```bash
api_contract -b api_contract_baseline.json --update-baseline   # first time: accepts what exists
api_contract -b api_contract_baseline.json                     # in CI: only new drift fails
```

The baseline is stored as fingerprints (`code|Model|key`) without line numbers, so it does not
break when you edit the file. `--update-baseline` on an existing file only **removes** what was
fixed, and never adds a new difference. If you really want to accept a new difference, add it to
the file by hand so it shows up in the review.

## 🤖 In GitHub Actions

```yaml
- uses: dart-lang/setup-dart@v1
- run: dart pub global activate flutter_api_contract
- run: api_contract --spec "${{ vars.API_SPEC_URL }}" --format github -b api_contract_baseline.json
```

## ❓ FAQ

**Why doesn't it run a build or build_runner?**
Because it only reads the source (syntactic). It understands `@JsonSerializable` and `@freezed`
from the annotations themselves, so it does not need the `.g.dart` files (and ignores them
anyway).

**My models are named differently from the schemas.**
Add the suffix to `suffixes:`, map them by hand in `models:`, or by endpoint in `endpoints:`.

**The API returns `{ "data": {...} }`.**
`endpoints: { ProfileModel: GET /me#data }`; the `#` walks into the properties (`#data.user`
works too).

**There is a key I know is not in the schema, on purpose.**
`ignore: [UserModel.localFlag]`, or put it in the baseline.

**Why is `int` vs `number` a warning and not an error?**
`json_serializable` generates `(x as num).toInt()`, so it will not crash, but you lose the
fractions. However, `as double` in a hand-written fromJson on an integer really does crash, which
is why that one is reported.

**The spec is protected by a token.**
`-H "Authorization: Bearer $TOKEN"` or `headers:` in the config (`${ENV}` is substituted from
the environment).

## ⚖️ Limitations

- The analysis is syntactic: there is no type resolution. Fields inherited from a superclass in
  `json_serializable` are not seen, and helpers outside the class (`_parseDate(json['d'])`) are
  treated as safe and untyped.
- A hand-written fromJson must read from the map parameter with a string literal
  (`json['key']`). Keys coming from variables or loops are not seen.
- `oneOf` / `anyOf` across several (non-`null`) shapes is skipped without a type check.
- `freezed` unions: the keys of all the factories are merged into one model, and the
  `runtimeType` discriminator is not checked.
- Converters (`@JsonKey(fromJson:)` and `@XConverter()`) disable the type check for that field.
- It only checks responses (what the app reads), not request bodies.

## 🛠 Tech stack

- Dart 3, `package:analyzer` (syntactic `parseString`, no resolution), `package:yaml`, `package:args`.
- `dart:io` `HttpClient` for remote specs; no other runtime dependencies.
- Tests with `package:test`, including a local HTTP server for URL loading and an end-to-end run
  against a vendored copy of the Swagger Petstore v3 spec.

## 🏗 Project structure

| File | Role |
|---|---|
| `bin/api_contract.dart` | CLI entry point |
| `lib/src/cli.dart` | argument parsing, baseline flow, exit codes |
| `lib/src/config.dart` | `api_contract.yaml` |
| `lib/src/spec/` | spec loading (file/URL, JSON/YAML) and the normalized schema model |
| `lib/src/dart/extractor.dart` | finds models and enums; `json_serializable` / `freezed` reads |
| `lib/src/dart/hand_written.dart` | follows `json['key']` reads through casts, `??`, guards and constructors |
| `lib/src/check/` | model ↔ schema matching, the checks, Levenshtein hints, baseline |
| `lib/src/report/report.dart` | text / Markdown / JSON / GitHub output |
| `test/` | unit tests, fixture specs (OpenAPI 3, Swagger 2, Petstore) and fixture apps |

## 🧑‍💻 Development

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

`test/fixtures/specs/petstore3.json` is a copy of the Swagger Petstore v3 sample spec
(Apache-2.0), used only for the end-to-end test.

## 📄 License

[MIT](LICENSE)

## 👤 Author

**Youssef Belal Zakaria** · [GitHub @youssef336](https://github.com/youssef336)

⭐ If you like this project, give it a star!
