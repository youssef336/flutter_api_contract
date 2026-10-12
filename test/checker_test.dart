import 'dart:io';

import 'package:flutter_api_contract/flutter_api_contract.dart';
import 'package:test/test.dart';

List<Finding> check(
  String dart,
  String specText, {
  ContractConfig? config,
  FieldRename rename = FieldRename.none,
}) => ContractChecker(
  project: extractFromSources({'lib/m.dart': dart}, globalRename: rename),
  spec: parseSpecText(specText),
  config: config ?? ContractConfig(),
).check();

Finding? find(List<Finding> findings, String code, [String? key]) {
  for (final f in findings) {
    if (f.code == code && (key == null || f.key == key)) return f;
  }
  return null;
}

const userSpec = '''
openapi: 3.0.0
components:
  schemas:
    User:
      type: object
      required: [id, user_name]
      properties:
        id: {type: integer}
        user_name: {type: string}
        nick: {type: string}
        email: {type: string, nullable: true}
        score: {type: number}
        tags: {type: array, items: {type: string}}
        role: {type: string, enum: [admin, member, guest]}
        born: {type: string, format: date}
''';

void main() {
  group('findings', () {
    test('missing-in-schema: unsafe read is an error with a suggestion', () {
      final f = find(
        check('''
class User {
  User(this.name);
  factory User.fromJson(Map<String, dynamic> json) =>
      User(json['userName'] as String);
  final String name;
}''', userSpec),
        Codes.missingInSchema,
        'userName',
      )!;
      expect(f.severity, Severity.error);
      expect(f.message, contains('CRASH RISK'));
      expect(f.suggestion, contains('"user_name"'));
    });

    test('missing-in-schema: nullable read is a warning', () {
      final f = find(
        check('''
class User {
  User(this.x);
  factory User.fromJson(Map<String, dynamic> json) =>
      User(json['avatar'] as String?);
  final String? x;
}''', userSpec),
        Codes.missingInSchema,
        'avatar',
      )!;
      expect(f.severity, Severity.warning);
      expect(f.suggestion, isNull);
    });

    test('required-ignored is info', () {
      final f = find(
        check('''
class User {
  User(this.id);
  factory User.fromJson(Map<String, dynamic> json) => User(json['id'] as int);
  final int id;
}''', userSpec),
        Codes.requiredIgnored,
        'user_name',
      )!;
      expect(f.severity, Severity.info);
    });

    test('nullable-mismatch for optional and for nullable fields', () {
      final findings = check('''
class User {
  User(this.nick, this.email, this.ok, this.alsoOk);
  factory User.fromJson(Map<String, dynamic> json) => User(
    json['nick'] as String,
    json['email'] as String,
    json['nick'] as String? ?? '',
    json['id'] as int,
  );
  final String nick;
  final String email;
  final String ok;
  final int alsoOk;
}''', userSpec);
      final nick = find(findings, Codes.nullableMismatch, 'nick')!;
      expect(nick.severity, Severity.error);
      expect(nick.message, contains('not required'));
      expect(
        find(findings, Codes.nullableMismatch, 'email')!.message,
        contains('nullable'),
      );
      expect(find(findings, Codes.nullableMismatch, 'id'), isNull);
    });

    test('nullable-mismatch for json_serializable without defaults', () {
      final findings = check(
        '''
@JsonSerializable()
class UserModel {
  UserModel(this.id, this.userName, this.nick, this.score);
  factory UserModel.fromJson(Map<String, dynamic> json) => _\$UserModelFromJson(json);
  final int id;
  final String userName;
  final String nick;
  @JsonKey(defaultValue: 0)
  final double score;
}''',
        userSpec,
        rename: FieldRename.snake,
      );
      expect(find(findings, Codes.nullableMismatch, 'nick'), isNotNull);
      expect(find(findings, Codes.nullableMismatch, 'score'), isNull);
      expect(find(findings, Codes.typeMismatch, 'score'), isNull);
      expect(find(findings, Codes.missingInSchema), isNull);
    });

    test('type-mismatch: String vs integer, int vs number, List vs object', () {
      final findings = check('''
class User {
  User(this.id, this.score, this.tags, this.role, this.born);
  factory User.fromJson(Map<String, dynamic> json) => User(
    json['id'] as String,
    json['score'] as int?,
    json['user_name'] as List?,
    json['role'] as bool?,
    json['born'] == null ? null : DateTime.parse(json['born'] as String),
  );
  final String id;
  final int? score;
  final List? tags;
  final bool? role;
  final DateTime? born;
}''', userSpec);
      expect(
        find(findings, Codes.typeMismatch, 'id')!.severity,
        Severity.error,
      );
      expect(
        find(findings, Codes.typeMismatch, 'score')!.severity,
        Severity.warning,
      );
      expect(find(findings, Codes.typeMismatch, 'user_name'), isNotNull);
      expect(find(findings, Codes.typeMismatch, 'role'), isNotNull);
      expect(find(findings, Codes.typeMismatch, 'born'), isNull);
    });

    test('type-mismatch: list item types and hand-written as double', () {
      final findings = check('''
class User {
  User(this.tags, this.score);
  factory User.fromJson(Map<String, dynamic> json) => User(
    (json['tags'] as List?)?.map((e) => e as int).toList() ?? [],
    json['score'] as double?,
  );
  final List<int> tags;
  final double? score;
}''', userSpec);
      expect(
        find(findings, Codes.typeMismatch, 'tags')!.message,
        contains('list items'),
      );
      expect(
        find(findings, Codes.typeMismatch, 'score')!.message,
        contains('toDouble'),
      );
    });

    test('enum-unhandled is an error without fallback, enum-extra is info', () {
      final findings = check('''
enum Role { admin, member, owner }
class User {
  User(this.role);
  factory User.fromJson(Map<String, dynamic> json) =>
      User(Role.values.byName(json['role'] as String? ?? 'admin'));
  final Role role;
}''', userSpec);
      final unhandled = find(findings, Codes.enumUnhandled, 'role')!;
      expect(unhandled.severity, Severity.error);
      expect(unhandled.message, contains('"guest"'));
      final extra = find(findings, Codes.enumExtra, 'role')!;
      expect(extra.severity, Severity.info);
      expect(extra.message, contains('"owner"'));
    });

    test('enum-unhandled is a warning with a fallback', () {
      final findings = check('''
enum Role { admin, member }
@JsonSerializable()
class User {
  User(this.role);
  factory User.fromJson(Map<String, dynamic> json) => _\$UserFromJson(json);
  @JsonKey(unknownEnumValue: Role.member)
  final Role? role;
}''', userSpec);
      expect(
        find(findings, Codes.enumUnhandled, 'role')!.severity,
        Severity.warning,
      );
    });

    test('unmatched-model is a warning with the closest schema', () {
      final f = find(
        check('''
class Usr {
  Usr(this.id);
  factory Usr.fromJson(Map<String, dynamic> json) => Usr(json['id'] as int);
  final int id;
}''', userSpec),
        Codes.unmatchedModel,
      )!;
      expect(f.severity, Severity.warning);
      expect(f.suggestion, contains('"User"'));
    });

    test('nested paths are checked through refs', () {
      final findings = check(
        '''
class Order {
  Order(this.city, this.zip);
  factory Order.fromJson(Map<String, dynamic> json) => Order(
    json['address']['city'] as String,
    json['address']['zipCode'] as String?,
  );
  final String city;
  final String? zip;
}''',
        '''
openapi: 3.0.0
components:
  schemas:
    Order:
      type: object
      required: [address]
      properties:
        address: {\$ref: '#/components/schemas/Address'}
    Address:
      type: object
      properties:
        city: {type: string}
        zip_code: {type: string}
''',
      );
      expect(find(findings, Codes.nullableMismatch, 'address.city'), isNotNull);
      final zip = find(findings, Codes.missingInSchema, 'address.zipCode')!;
      expect(zip.message, contains('Address has no "zipCode"'));
      expect(zip.suggestion, contains('zip_code'));
      expect(find(findings, Codes.nullableMismatch, 'address'), isNull);
    });

    test('nested model ref pointing at a different schema warns', () {
      final findings = check(
        '''
class A {
  A(this.b);
  factory A.fromJson(Map<String, dynamic> json) =>
      A(BModel.fromJson(json['b'] as Map<String, dynamic>));
  final BModel b;
}
class BModel {
  BModel(this.x);
  factory BModel.fromJson(Map<String, dynamic> json) => BModel(json['x'] as int);
  final int x;
}''',
        '''
openapi: 3.0.0
components:
  schemas:
    A:
      type: object
      required: [b]
      properties:
        b: {\$ref: '#/components/schemas/C'}
    B: {type: object, required: [x], properties: {x: {type: integer}}}
    C: {type: object, properties: {x: {type: integer}}}
''',
      );
      final f = find(findings, Codes.typeMismatch, 'b')!;
      expect(f.severity, Severity.warning);
      expect(f.message, contains('refers to C'));
    });
  });

  group('matching', () {
    const spec = '''
openapi: 3.0.0
paths:
  /me:
    get:
      responses:
        '200':
          content:
            application/json:
              schema:
                type: object
                properties:
                  data: {\$ref: '#/components/schemas/Profile'}
  /items:
    get:
      responses:
        '200':
          content:
            application/json:
              schema: {type: array, items: {\$ref: '#/components/schemas/ItemDto'}}
components:
  schemas:
    Profile: {type: object, properties: {name: {type: string}}}
    ItemDto: {type: object, properties: {id: {type: integer}}}
    WalletResponse: {type: object, properties: {balance: {type: number}}}
''';
    String model(String name, String key) =>
        '''
class $name {
  $name(this.v);
  factory $name.fromJson(Map<String, dynamic> json) => $name(json['$key']);
  final Object? v;
}
''';

    MatchResult run(String dart, ContractConfig config) => ContractChecker(
      project: extractFromSources({'lib/m.dart': dart}),
      spec: parseSpecText(spec),
      config: config,
    ).match;

    test('by name with suffixes stripped on both sides', () {
      final m = run(
        model('ItemModel', 'id') + model('WalletDto', 'balance'),
        ContractConfig(),
      );
      final pairs = {for (final x in m.matches) x.model.name: x.schemaName};
      expect(pairs, {'ItemModel': 'ItemDto', 'WalletDto': 'WalletResponse'});
      expect(m.matches.every((x) => x.via == MatchVia.suffix), isTrue);
    });

    test('explicit mapping, endpoint with envelope, and skip', () {
      final m = run(
        model('Me', 'name') + model('Purse', 'balance') + model('Tmp', 'x'),
        ContractConfig(
          models: {'Purse': 'WalletResponse', 'Tmp': null},
          endpoints: {'Me': 'GET /me#data'},
        ),
      );
      final pairs = {for (final x in m.matches) x.model.name: x.via};
      expect(pairs, {'Me': MatchVia.endpoint, 'Purse': MatchVia.config});
      expect(
        m.matches.firstWhere((x) => x.model.name == 'Me').schemaName,
        'Profile',
      );
      expect(m.skipped.map((x) => x.name), ['Tmp']);
    });

    test('endpoint returning an array uses the item schema', () {
      final m = run(
        model('Row', 'id'),
        ContractConfig(endpoints: {'Row': 'get /items'}),
      );
      expect(m.matches.single.schemaName, 'ItemDto');
    });

    test('config pointing nowhere is an unknown-schema error', () {
      final findings = ContractChecker(
        project: extractFromSources({
          'lib/m.dart': model('A', 'x') + model('B', 'y'),
        }),
        spec: parseSpecText(spec),
        config: ContractConfig(
          models: {'A': 'Nope'},
          endpoints: {'B': 'GET /missing'},
        ),
      ).check();
      expect(
        findings
            .where((f) => f.code == Codes.unknownSchema)
            .map((f) => f.model),
        ['A', 'B'],
      );
      expect(findings.every((f) => f.severity == Severity.error), isTrue);
    });

    test('ignore skips models and keys', () {
      final findings = ContractChecker(
        project: extractFromSources({
          'lib/m.dart': model('Profile', 'missing') + model('Gone', 'x'),
        }),
        spec: parseSpecText(spec),
        config: ContractConfig(ignore: {'Profile.missing', 'Gone'}),
      ).check();
      expect(findings, isEmpty);
    });
  });

  test('Swagger 2 fixture end to end', () {
    final findings = check('''
enum PetStatus { available, sold }
class PetModel {
  PetModel(this.id, this.name, this.nickname, this.status, this.photos);
  factory PetModel.fromJson(Map<String, dynamic> json) => PetModel(
    json['id'] as int,
    json['name'] as String,
    json['nickname'] as String,
    PetStatus.values.byName(json['status'] as String),
    (json['photoUrls'] as List).cast<String>(),
  );
  final int id;
  final String name;
  final String nickname;
  final PetStatus status;
  final List<String> photos;
}''', File('test/fixtures/specs/swagger2.json').readAsStringSync());
    expect(find(findings, Codes.nullableMismatch, 'nickname'), isNotNull);
    expect(find(findings, Codes.nullableMismatch, 'status'), isNotNull);
    expect(find(findings, Codes.enumUnhandled, 'status'), isNotNull);
    expect(
      find(findings, Codes.missingInSchema, 'photoUrls')!.suggestion,
      contains('photo_urls'),
    );
    expect(find(findings, Codes.nullableMismatch, 'id'), isNull);
  });

  group('closest()', () {
    test('separator/case changes win, far names are dropped', () {
      expect(closest('userName', ['user_name', 'username2']), 'user_name');
      expect(closest('long', ['lat', 'lng']), 'lng');
      expect(closest('avatar', ['id', 'email']), isNull);
      expect(levenshtein('kitten', 'sitting'), 3);
    });
  });
}
