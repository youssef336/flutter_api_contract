[English](README.md)

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

<div dir="rtl">

الـ backend غيّر اسم field، أو خلّاه optional، أو زوّد قيمة جديدة في enum... والـ app بتاعك
لسه فاكر الشكل القديم. النتيجة: `type 'Null' is not a subtype of type 'String'` في
production. الأداة دي بتقارن الـ models اللي في كودك Dart بالـ OpenAPI / Swagger بتاع الـ
backend، وبتقولك على الفرق **قبل** ما يوصل للمستخدم.

## ✨ بتعمل إيه

- 📄 **بتقرا الـ spec**: OpenAPI 3.0 و 3.1 و Swagger 2.0، JSON أو YAML، من فايل أو من لينك
  (`--spec https://api.example.com/docs-json`). بتفهم `$ref` و `allOf` و `nullable` و
  `type: [string, 'null']` و `x-nullable` و `anyOf` فيه `null`.
- 🔍 **بتقرا الـ models من الكود نفسه** (بـ `package:analyzer`، من غير ما تعمل build):
  - **fromJson مكتوب بإيدك**: `json['key']`، و `as String` / `as String?`، و `??`، و
    `json['x'] == null ? null : ...`، و `json['a']['b']`، و `final data = json['data']`،
    و `DateTime.parse`، و `X.fromJson(...)`، و `Status.values.byName(...)` و
    `firstWhere(..., orElse: ...)`.
  - **json_serializable**: `@JsonKey(name:, defaultValue:, includeFromJson:, unknownEnumValue:)`،
    و `fieldRename` على الكلاس، و `field_rename` العام في `build.yaml`، والـ default بتاع الـ
    constructor.
  - **freezed**: params الـ factory، و `@Default`، و `@JsonKey`، و `@JsonSerializable` على الـ
    factory، والـ unions.
  - **enums**: `@JsonValue`، و `@JsonEnum(fieldRename:, valueField:)`، والـ `case 'x':` في
    parser مكتوب بإيدك.
- 🔗 **بتربط كل model بالـ schema بتاعته**: بالاسم (`UserModel` / `UserDto` / `User` ↔
  `components.schemas.User` بعد ما تشيل الـ suffixes)، أو بـ mapping صريح في
  `api_contract.yaml`، أو بالـ endpoint (`ProfileModel: GET /me#data`).
- 🚨 **بتطلّع الفروق دي**:

  | الكود | الخطورة | يعني |
  |---|---|---|
  | `nullable-mismatch` | 🔴 error | الـ schema بتقول الـ field ممكن ييجي `null` أو مايجيش، والكود بيقراه non-nullable من غير default → **crash** |
  | `missing-in-schema` | 🔴 / 🟡 | الكود بيقرا key مش موجود في الـ schema (غالبًا اتغيّر اسمه)، وبيقترح أقرب اسم: «did you mean `user_name`?» |
  | `type-mismatch` | 🔴 / 🟡 | `int` قصاد `string`، `List` قصاد `object`، `int` قصاد `number` (كسور)، `as double` قصاد رقم صحيح |
  | `enum-unhandled` | 🔴 / 🟡 | الـ schema فيها قيمة الـ enum بتاعك مايعرفهاش. error لو مفيش fallback، warning لو فيه |
  | `enum-extra` | 🔵 info | الـ enum بتاعك فيه قيم الـ schema عمرها ما بتبعتها |
  | `required-ignored` | 🔵 info | field مطلوب في الـ schema والكود مش بيقراه خالص |
  | `unmatched-model` | 🟡 warning | model ملوش schema، وبيقولك أقرب schema لاسمه |
  | `unknown-schema` | 🔴 error | الـ config بيشاور على schema أو endpoint مش موجود |

- 📤 **4 أشكال للنتيجة**: `text` (للـ terminal)، و `markdown` (تحطه في PR)، و `json`، و `github`
  (annotations جنب السطر في الـ PR).
- 🚦 **بتوقف الـ CI**: exit code `1` لو فيه error (أو warning بـ `--fail-on warning`).
- 📉 **baseline بيقل بس**: لو مشروعك فيه فروق قديمة، اقبلها مرة واحدة وكمّل. أي فرق
  **جديد** هيظهر، والقديم لما يتصلح بيتشال من الـ baseline ومش بيرجع تاني.

## 📦 التسطيب

محتاج Dart 3.11 أو أحدث (أو Flutter فيه Dart ده).

```bash
dart pub global activate flutter_api_contract
```

أو جوه المشروع كـ dev dependency:

```yaml
dev_dependencies:
  flutter_api_contract: ^0.1.0
```

```bash
dart run flutter_api_contract:api_contract --spec openapi.json
```

## 🚀 الاستخدام

```bash
# من root مشروع الـ Flutter
api_contract --spec https://api.example.com/docs-json
api_contract --spec docs/openapi.yaml --format markdown > drift.md
api_contract --spec "$SPEC_URL" -H "Authorization: Bearer $DOCS_TOKEN" --format github
```

| الـ option | بيعمل إيه |
|---|---|
| `-s, --spec` | فايل أو لينك الـ spec (بيغطي على `spec:` في الـ config) |
| `-p, --project` | root المشروع (الافتراضي `.`) |
| `-c, --config` | فايل الـ config (الافتراضي `api_contract.yaml`) |
| `-f, --format` | `text` · `markdown` · `json` · `github` |
| `--fail-on` | `error` (الافتراضي) · `warning` · `never` |
| `-b, --baseline` | فايل JSON فيه الفروق المقبولة |
| `--update-baseline` | يعمل الـ baseline لو مش موجود، أو يصغّره بس لو موجود |
| `-H, --header` | header لتحميل الـ spec (تقدر تكررها) |
| `--[no-]color` | ألوان ANSI |

الـ exit codes: `0` مفيش مشاكل · `1` فيه فروق عند مستوى `--fail-on` · `2` غلط في الأمر أو الـ spec.

## 🧪 شكل النتيجة

ده تشغيل حقيقي على الـ [Swagger Petstore v3](https://petstore3.swagger.io/api/v3/openapi.json)
مع app صغير فيه 3 فروق متعمّدة (موجود في `test/fixtures/petstore_app`):

</div>

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

<div dir="rtl">

## ⚙️ الـ config (اختياري)

حط `api_contract.yaml` في root المشروع (فيه نسخة كاملة في `api_contract.example.yaml`):

</div>

```yaml
spec: https://api.example.com/docs-json
paths: [lib]
exclude: ['lib/legacy/**']
suffixes: [Model, Dto, DTO, Response, Entity, Data, Json]
models:
  WalletModel: WalletResponse   # اسم الـ schema بالظبط
  DraftPost: null               # model محلي، متفحصهوش
endpoints:
  ProfileModel: GET /me#data    # الـ response بتاع الـ endpoint، و #data بتفك الـ envelope
ignore:
  - AnalyticsEvent              # model كامل
  - UserModel.legacyField       # key واحد
headers:
  Authorization: Bearer ${DOCS_TOKEN}
baseline: api_contract_baseline.json
```

<div dir="rtl">

## 📉 الـ baseline

```bash
api_contract -b api_contract_baseline.json --update-baseline   # أول مرة: يقبل الموجود
api_contract -b api_contract_baseline.json                     # في الـ CI: الجديد بس هو اللي بيفشّل
```

الـ baseline بيتحفظ كـ fingerprints (`code|Model|key`) من غير أرقام سطور، فمش بيبوظ لما
تعدّل الفايل. `--update-baseline` على فايل موجود **بيشيل** اللي اتصلح بس، وعمره ما بيزوّد
فرق جديد. لو عايز تقبل فرق جديد بجد، زوّده بإيدك في الفايل عشان يبان في الـ review.

## 🤖 في GitHub Actions

</div>

```yaml
- uses: dart-lang/setup-dart@v1
- run: dart pub global activate flutter_api_contract
- run: api_contract --spec "${{ vars.API_SPEC_URL }}" --format github -b api_contract_baseline.json
```

<div dir="rtl">

## ❓ أسئلة

**ليه مش بيعمل build ولا بيشغّل build_runner؟**
لأنه بيقرا الـ source بس (syntactic). بيفهم `@JsonSerializable` و `@freezed` من الـ
annotations نفسها، فمش محتاج الـ `.g.dart` (وبيتجاهلها أصلًا).

**الـ models بتاعتي اسمها مختلف عن الـ schemas.**
زوّد الـ suffix في `suffixes:`، أو اربطها بإيدك في `models:`، أو بالـ endpoint في `endpoints:`.

**الـ API بيرجع `{ "data": {...} }`.**
`endpoints: { ProfileModel: GET /me#data }`، والـ `#` بتمشي جوه الـ properties (`#data.user` كمان شغالة).

**فيه key عارف إنه مش في الـ schema وده مقصود.**
`ignore: [UserModel.localFlag]`، أو حطه في الـ baseline.

**ليه `int` قصاد `number` warning مش error؟**
`json_serializable` بيعمل `(x as num).toInt()`، فمش هيعمل crash، بس هتخسر الكسور.
لكن `as double` في fromJson مكتوب بإيدك على رقم صحيح بيعمل crash فعلًا، عشان كده بيطلع.

**الـ spec محمي بـ token.**
`-H "Authorization: Bearer $TOKEN"` أو `headers:` في الـ config (`${ENV}` بتتبدّل من الـ environment).

## ⚖️ الحدود

- التحليل syntactic: مفيش type resolution. الـ fields اللي جاية بالوراثة من superclass في
  `json_serializable` مش بتتشاف، والـ helpers اللي برّه الكلاس (`_parseDate(json['d'])`)
  بتتعامل إنها آمنة ومن غير type.
- الـ fromJson المكتوب بإيدك لازم يقرا من الـ map parameter بـ string literal
  (`json['key']`). الـ keys اللي جاية من متغيرات أو loops مش بتتشاف.
- الـ `oneOf` / `anyOf` بين أكتر من شكل (مش `null`) بيتعدّى من غير type check.
- `freezed` unions: الـ keys بتاعة كل الـ factories بتتجمع في model واحد، والـ
  `runtimeType` discriminator مش بيتفحص.
- الـ converters (`@JsonKey(fromJson:)` و `@XConverter()`) بتلغي فحص الـ type للـ field ده.
- بيفحص الـ responses بس (اللي الـ app بيقراه)، مش الـ request bodies.

</div>

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
