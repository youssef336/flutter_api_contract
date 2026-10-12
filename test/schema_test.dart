import 'dart:io';

import 'package:flutter_api_contract/flutter_api_contract.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAPI 3', () {
    late ApiSpec spec;
    setUpAll(() {
      spec = parseSpecText(
        File('test/fixtures/specs/openapi3.yaml').readAsStringSync(),
      );
    });

    test('reads label and schemas from YAML', () {
      expect(spec.label, 'OpenAPI 3.0.3');
      expect(spec.schemas.keys, containsAll(['User', 'Address', 'Session']));
    });

    test('properties, required, nullable, formats', () {
      final user = spec.resolve(spec.schemas['User']!);
      expect(user.type, JsonType.object);
      expect(user.required, contains('user_name'));
      expect(user.properties['id']!.type, JsonType.integer);
      expect(user.properties['id']!.format, 'int64');
      expect(user.properties['email']!.nullable, isTrue);
      expect(user.properties['display_name']!.nullable, isFalse);
      expect(user.properties['tags']!.items!.type, JsonType.string);
    });

    test(r'$ref resolves to the target, keeping the ref name', () {
      final status = spec.resolve(
        spec.resolve(spec.schemas['User']!).properties['status']!,
      );
      expect(status.ref, 'UserStatus');
      expect(status.enumValues, ['active', 'banned', 'pending']);
    });

    test('success responses are indexed by METHOD path', () {
      expect(spec.responses.keys, containsAll(['GET /me', 'GET /wallet']));
      expect(spec.responses['GET /wallet']!.ref, 'WalletDetails');
    });
  });

  group('OpenAPI 3.1 and composition', () {
    final spec = parseSpecText('''
{
  "openapi": "3.1.0",
  "components": {"schemas": {
    "Base": {"type": "object", "required": ["id"],
             "properties": {"id": {"type": "integer"}}},
    "Child": {"allOf": [{"\$ref": "#/components/schemas/Base"},
              {"type": "object", "properties": {"name": {"type": ["string", "null"]}}}]},
    "Holder": {"type": "object", "properties": {
      "a": {"anyOf": [{"\$ref": "#/components/schemas/Base"}, {"type": "null"}]},
      "b": {"allOf": [{"\$ref": "#/components/schemas/Base"}], "nullable": true},
      "c": {"oneOf": [{"type": "string"}, {"type": "integer"}]},
      "d": {"type": "string", "enum": ["x", "y", null]},
      "self": {"\$ref": "#/components/schemas/Holder"}
    }}
  }}
}''');

    test('type arrays with null are nullable', () {
      final child = spec.resolve(spec.schemas['Child']!);
      expect(child.properties['name']!.nullable, isTrue);
      expect(child.properties['name']!.type, JsonType.string);
    });

    test('allOf merges properties and required', () {
      final child = spec.resolve(spec.schemas['Child']!);
      expect(child.properties.keys, containsAll(['id', 'name']));
      expect(child.required, {'id'});
    });

    test('anyOf [ref, null] and nullable single allOf are nullable refs', () {
      final holder = spec.resolve(spec.schemas['Holder']!);
      final a = holder.properties['a']!;
      expect(a.ref, 'Base');
      expect(a.nullable, isTrue);
      final b = spec.resolve(holder.properties['b']!);
      expect(b.ref, 'Base');
      expect(b.nullable, isTrue);
      expect(b.properties.keys, ['id']);
    });

    test('a real oneOf is a union, an enum with null is nullable', () {
      final holder = spec.resolve(spec.schemas['Holder']!);
      expect(holder.properties['c']!.isUnion, isTrue);
      expect(holder.properties['d']!.nullable, isTrue);
      expect(holder.properties['d']!.enumValues, ['x', 'y']);
    });

    test('recursive refs do not loop', () {
      final holder = spec.resolve(spec.schemas['Holder']!);
      final self = spec.resolve(holder.properties['self']!);
      expect(self.ref, 'Holder');
      expect(spec.resolve(self.properties['self']!).ref, 'Holder');
    });
  });

  group('Swagger 2', () {
    final spec = parseSpecText(
      File('test/fixtures/specs/swagger2.json').readAsStringSync(),
    );

    test('reads definitions, x-nullable and responses', () {
      expect(spec.label, 'Swagger 2.0');
      final pet = spec.resolve(spec.schemas['Pet']!);
      expect(pet.properties['nickname']!.nullable, isTrue);
      expect(pet.properties['owner']!.ref, 'Owner');
      expect(spec.responses['GET /pets/{id}']!.ref, 'Pet');
      expect(spec.responses['GET /pets']!.type, JsonType.array);
    });
  });

  test('refName decodes JSON pointers', () {
    expect(refName('#/components/schemas/Pet'), 'Pet');
    expect(refName('#/definitions/a~1b'), 'a/b');
    expect(refName('models/User.json'), 'User');
  });

  test('describe() is readable', () {
    expect(
      parseSchema({'type': 'integer', 'format': 'int64'}).describe(),
      'integer(int64)',
    );
    expect(
      parseSchema({
        'type': 'array',
        'items': {r'$ref': '#/definitions/Pet'},
      }).describe(),
      'array<Pet>',
    );
  });

  test('non-spec documents are rejected', () {
    expect(() => parseSpecText('{"hello": 1}'), throwsA(isA<SpecException>()));
    expect(() => parseSpecText('[1, 2]'), throwsA(isA<SpecException>()));
    expect(() => parseSpecText('{oops'), throwsA(isA<SpecException>()));
  });

  test('missing file is a SpecException', () async {
    await expectLater(
      loadSpec('does/not/exist.json'),
      throwsA(isA<SpecException>()),
    );
  });
}
