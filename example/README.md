# Example

A Flutter app whose `UserModel` has drifted from the backend's OpenAPI spec, and what
`api_contract` reports for it.

## Project

```text
my_app/
├── api_contract.yaml
├── docs/openapi.yaml
└── lib/models/user_model.dart
```

`docs/openapi.yaml` (what the backend documents; `GET /me` returns `{ "data": User }`):

```yaml
openapi: 3.0.3
info:
  title: Shop API
  version: 1.0.0
paths:
  /me:
    get:
      responses:
        '200':
          description: The signed-in user.
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    $ref: '#/components/schemas/User'
components:
  schemas:
    User:
      type: object
      required: [id, user_name, role]
      properties:
        id:
          type: integer
        user_name:
          type: string
        avatar_url:
          type: string
          nullable: true
        role:
          type: string
          enum: [admin, member, guest]
```

`lib/models/user_model.dart` (what the app expects):

```dart
enum Role { admin, member }

class UserModel {
  UserModel({
    required this.id,
    required this.name,
    required this.avatarUrl,
    required this.role,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) => UserModel(
        id: json['id'] as int,
        name: json['username'] as String,
        avatarUrl: json['avatar_url'] as String,
        role: Role.values.byName(json['role'] as String),
      );

  final int id;
  final String name;
  final String avatarUrl;
  final Role role;
}
```

`api_contract.yaml` (pairs the model with the response of `GET /me`, unwrapping `data`):

```yaml
spec: docs/openapi.yaml
paths: [lib]
endpoints:
  UserModel: GET /me#data
```

## Run it

```bash
dart pub global activate flutter_api_contract
cd my_app
api_contract --no-color
```

```text
API contract check · OpenAPI 3.0.3 (openapi.yaml) · 1 schemas · 1 models

UserModel → User  lib/models/user_model.dart
  error    nullable-mismatch  avatar_url  lib/models/user_model.dart:14
           "avatar_url" is nullable and not required in User, but the app reads it as non-nullable `String` with no default (CRASH RISK).
           → make `avatarUrl` nullable or give it a default (`??`, @Default, defaultValue)
  error    enum-unhandled  role  lib/models/user_model.dart:15
           enum Role does not know "guest" from the schema, and parsing an unknown value throws (CRASH RISK).
           → add the values, or a fallback (@JsonKey(unknownEnumValue: ...) / orElse:)
  error    missing-in-schema  username  lib/models/user_model.dart:13
           "username" is read by the app but User has no "username", and the read throws when it is absent (CRASH RISK).
           → did you mean "user_name"? (likely a backend rename)
  info     required-ignored  user_name  lib/models/user_model.dart:3
           "user_name" is required in User but UserModel never reads it.

3 errors · 0 warnings · 1 info
```

The exit code is `1` because there are errors. Each finding is a crash waiting to happen:
`avatar_url` can be `null`, the backend sends `user_name` (not `username`), and a `guest` role
would make `Role.values.byName` throw.

## Other formats

```bash
api_contract --format markdown > drift.md        # for a PR comment
api_contract --format github                     # inline annotations in GitHub Actions
api_contract --format json                       # for other tools
api_contract --spec https://api.example.com/docs-json -H "Authorization: Bearer $DOCS_TOKEN"
```

## Adopting it on an existing project

Accept today's drift once, then let CI fail only on new drift:

```bash
api_contract -b api_contract_baseline.json --update-baseline
api_contract -b api_contract_baseline.json
```

`api_contract_baseline.json` stores fingerprints without line numbers:

```json
{
  "version": 1,
  "findings": [
    "enum-unhandled|UserModel|role",
    "missing-in-schema|UserModel|username",
    "nullable-mismatch|UserModel|avatar_url",
    "required-ignored|UserModel|user_name"
  ]
}
```
