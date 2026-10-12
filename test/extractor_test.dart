import 'package:flutter_api_contract/flutter_api_contract.dart';
import 'package:test/test.dart';

DartProject extract(
  String source, {
  FieldRename rename = FieldRename.none,
  Map<String, String> extra = const {},
}) => extractFromSources({
  'lib/model.dart': source,
  ...extra,
}, globalRename: rename);

FieldRead readOf(DartProject project, String model, String key) =>
    project.models[model]!.reads.firstWhere((r) => r.displayKey == key);

void main() {
  group('DartType', () {
    test('parses generics, nullability and prefixes', () {
      final t = DartType.parse('List<Map<String, dynamic>?>?');
      expect(t.name, 'List');
      expect(t.nullable, isTrue);
      expect(t.args.single.name, 'Map');
      expect(t.args.single.nullable, isTrue);
      expect(t.args.single.args.map((a) => a.name), ['String', 'dynamic']);
      expect(DartType.parse('m.Pet').name, 'Pet');
      expect(t.toString(), 'List<Map<String, dynamic>?>?');
    });
  });

  group('FieldRename', () {
    test('matches json_serializable', () {
      expect(FieldRename.snake.apply('userName'), 'user_name');
      expect(FieldRename.snake.apply('userID'), 'user_i_d');
      expect(FieldRename.kebab.apply('userName'), 'user-name');
      expect(FieldRename.pascal.apply('userName'), 'UserName');
      expect(FieldRename.screamingSnake.apply('userName'), 'USER_NAME');
      expect(FieldRename.tryParse('FieldRename.snake'), FieldRename.snake);
      expect(
        FieldRename.tryParse('screaming_snake'),
        FieldRename.screamingSnake,
      );
      expect(FieldRename.tryParse('nope'), isNull);
    });
  });

  group('hand-written fromJson', () {
    final project = extract(
      '''
import 'other.dart';

enum Kind { a, b }

class Item {
  Item(this.title, {required this.price, this.note, required this.tags,
      required this.kind, required this.when, required this.count,
      required this.label, required this.mode, required this.child,
      required this.children, this.missing});

  factory Item.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'] as Map<String, dynamic>;
    return Item(
      json['title'] as String,
      price: (json['price'] as num).toDouble(),
      note: json['note'] as String?,
      tags: (json['tags'] as List?)?.cast<String>() ?? const [],
      kind: Kind.values.byName(json['kind'] as String),
      when: DateTime.parse(json['when'] as String),
      count: int.parse(json['count']),
      label: json['label'].toString(),
      mode: Kind.values.firstWhere((k) => k.name == json['mode'],
          orElse: () => Kind.a),
      child: json['child'] != null ? Other.fromJson(json['child']) : null,
      children: (json['children'] as List)
          .map((e) => Other.fromJson(e as Map<String, dynamic>))
          .toList(),
      missing: json['deep']['er']['est'] as int?,
      version: meta['version'] as int,
    );
  }

  final String title;
  final double price;
  final String? note;
  final List<String> tags;
  final Kind kind;
  final DateTime when;
  final int count;
  final String label;
  final Kind mode;
  final Other? child;
  final List<Other> children;
  final int? missing;
}
''',
      extra: {
        'lib/other.dart': '''
class Other {
  Other(this.x);
  factory Other.fromJson(Map<String, dynamic> json) => Other(json['x'] as int);
  final int x;
}
''',
      },
    );

    test('is detected as hand-written', () {
      expect(project.models['Item']!.kind, ModelKind.handWritten);
      expect(project.models.keys, containsAll(['Item', 'Other']));
    });

    test('non-nullable cast is unsafe, nullable cast is safe', () {
      expect(readOf(project, 'Item', 'title').nullSafe, isFalse);
      expect(readOf(project, 'Item', 'title').type.toString(), 'String');
      expect(readOf(project, 'Item', 'note').nullSafe, isTrue);
    });

    test('positional and named constructor args map to fields', () {
      expect(readOf(project, 'Item', 'title').fieldName, 'title');
      expect(readOf(project, 'Item', 'note').fieldName, 'note');
    });

    test('(as num).toDouble() keeps the cast type', () {
      final price = readOf(project, 'Item', 'price');
      expect(price.type!.name, 'num');
      expect(price.nullSafe, isFalse);
    });

    test('?. and ?? are null-safe', () {
      final tags = readOf(project, 'Item', 'tags');
      expect(tags.nullSafe, isTrue);
      expect(tags.type!.name, 'List');
    });

    test('values.byName is an enum without fallback', () {
      final kind = readOf(project, 'Item', 'kind');
      expect(kind.enumName, 'Kind');
      expect(kind.enumFallback, isFalse);
      expect(kind.nullSafe, isFalse);
    });

    test('firstWhere with orElse is an enum with fallback', () {
      final mode = readOf(project, 'Item', 'mode');
      expect(mode.enumName, 'Kind');
      expect(mode.enumFallback, isTrue);
    });

    test('DateTime.parse and int.parse set the wire type', () {
      expect(readOf(project, 'Item', 'when').type!.name, 'DateTime');
      expect(readOf(project, 'Item', 'count').type!.name, 'String');
      expect(readOf(project, 'Item', 'count').nullSafe, isFalse);
    });

    test('toString() tolerates null and hides the type', () {
      final label = readOf(project, 'Item', 'label');
      expect(label.nullSafe, isTrue);
      expect(label.type, isNull);
    });

    test('a null guard makes X.fromJson safe; the guard is not a type', () {
      final child = readOf(project, 'Item', 'child');
      expect(child.nullSafe, isTrue);
      expect(child.type!.name, 'Other');
    });

    test('List of nested models via map(fromJson)', () {
      final children = readOf(project, 'Item', 'children');
      expect(children.type.toString(), 'List<Other>');
      expect(children.nullSafe, isFalse);
    });

    test('nested chains record the path and the parent maps', () {
      expect(readOf(project, 'Item', 'deep.er.est').nullSafe, isTrue);
      expect(readOf(project, 'Item', 'deep.er').nullSafe, isFalse);
      expect(readOf(project, 'Item', 'deep').nullSafe, isFalse);
      expect(readOf(project, 'Item', 'deep').type!.name, 'Map');
    });

    test('aliases (final meta = json[...]) extend the path', () {
      expect(readOf(project, 'Item', 'meta.version').type!.name, 'int');
      expect(readOf(project, 'Item', 'meta').nullSafe, isFalse);
    });
  });

  test('generative fromJson constructor with initializers and fromMap', () {
    final project = extract('''
class A {
  A.fromJson(Map<String, dynamic> m)
      : id = m['id'] as int,
        name = m['name'];
  final int id;
  final String? name;
}
class B {
  B(this.v);
  static B fromMap(Map<String, dynamic> data) => B(data['v'] as bool? ?? false);
  final bool v;
}
''');
    expect(readOf(project, 'A', 'id').nullSafe, isFalse);
    expect(readOf(project, 'A', 'name').nullSafe, isTrue);
    expect(readOf(project, 'A', 'name').type.toString(), 'String?');
    final v = readOf(project, 'B', 'v');
    expect(v.nullSafe, isTrue);
    expect(v.hasDefault, isTrue);
  });

  test('implicit downcast into a non-nullable field is unsafe', () {
    final project = extract('''
class C {
  C({required this.name});
  factory C.fromJson(Map<String, dynamic> json) => C(name: json['name']);
  final String name;
}
''');
    final name = readOf(project, 'C', 'name');
    expect(name.nullSafe, isFalse);
    expect(name.type!.name, 'String');
  });

  group('json_serializable', () {
    const source = '''
@JsonSerializable()
class Global {
  Global({required this.userName, this.count = 3});
  factory Global.fromJson(Map<String, dynamic> json) => _\$GlobalFromJson(json);
  final String userName;
  final int count;
  static const version = 1;
  final String computed = 'x';
}

@JsonSerializable(fieldRename: FieldRename.kebab)
class Local {
  Local(this.firstName, this.status, this.at, this.skip, this.old, this.renamed,
      this.withDefault);
  factory Local.fromJson(Map<String, dynamic> json) => _\$LocalFromJson(json);
  final String firstName;
  @JsonKey(unknownEnumValue: Status.unknown)
  final Status status;
  @EpochConverter()
  final DateTime at;
  @JsonKey(includeFromJson: false)
  final String? skip;
  @JsonKey(ignore: true)
  final String? old;
  @JsonKey(name: 'REAL')
  final String renamed;
  @JsonKey(defaultValue: 0)
  final int withDefault;
}

@JsonSerializable(createFactory: false)
class ToJsonOnly {
  ToJsonOnly(this.a);
  final String a;
}
''';

    test('global build.yaml rename applies', () {
      final project = extract(source, rename: FieldRename.snake);
      final g = project.models['Global']!;
      expect(g.kind, ModelKind.jsonSerializable);
      expect(g.reads.map((r) => r.key), ['user_name', 'count']);
      expect(readOf(project, 'Global', 'user_name').nullSafe, isFalse);
      expect(readOf(project, 'Global', 'count').hasDefault, isTrue);
      expect(readOf(project, 'Global', 'count').nullSafe, isTrue);
    });

    test('class fieldRename overrides global; JsonKey options', () {
      final project = extract(source, rename: FieldRename.snake);
      final keys = project.models['Local']!.reads.map((r) => r.key).toList();
      expect(keys, ['first-name', 'status', 'at', 'REAL', 'with-default']);
      expect(readOf(project, 'Local', 'status').enumFallback, isTrue);
      expect(readOf(project, 'Local', 'at').customConverter, isTrue);
      expect(readOf(project, 'Local', 'with-default').nullSafe, isTrue);
      expect(readOf(project, 'Local', 'REAL').nullSafe, isFalse);
    });

    test('createFactory: false is not a model', () {
      expect(extract(source).models.containsKey('ToJsonOnly'), isFalse);
    });
  });

  group('freezed', () {
    test('reads factory params with @Default and @JsonKey', () {
      final project = extract('''
@freezed
abstract class User with _\$User {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory User({
    required String firstName,
    @JsonKey(name: 'mail') String? email,
    @Default(0) int loginCount,
    @JsonKey(includeFromJson: false, includeToJson: false) String? local,
  }) = _User;
  const User._();
  factory User.fromJson(Map<String, dynamic> json) => _\$UserFromJson(json);
}

@freezed
class NoJson with _\$NoJson {
  const factory NoJson(int a) = _NoJson;
}
''');
      final user = project.models['User']!;
      expect(user.kind, ModelKind.freezed);
      expect(user.reads.map((r) => r.key), [
        'first_name',
        'mail',
        'login_count',
      ]);
      expect(readOf(project, 'User', 'first_name').nullSafe, isFalse);
      expect(readOf(project, 'User', 'login_count').hasDefault, isTrue);
      expect(project.models.containsKey('NoJson'), isFalse);
    });

    test('union factories are merged', () {
      final project = extract('''
@freezed
sealed class Shape with _\$Shape {
  const factory Shape.circle(double radius) = Circle;
  const factory Shape.square(double side) = Square;
  factory Shape.fromJson(Map<String, dynamic> json) => _\$ShapeFromJson(json);
}
''');
      expect(project.models['Shape']!.reads.map((r) => r.key), [
        'radius',
        'side',
      ]);
    });
  });

  group('enums', () {
    final project = extract('''
enum Plain { one, two }

enum Annotated {
  @JsonValue('first') a,
  @JsonValue(2) b,
}

@JsonEnum(fieldRename: FieldRename.snake)
enum Renamed { fooBar, baz }

@JsonEnum(valueField: 'code')
enum Coded {
  ok(200, 'fine'),
  missing(404, 'gone');
  const Coded(this.code, this.text);
  final int code;
  final String text;
}

enum Switched {
  on, off;
  static Switched fromJson(String v) => switch (v) {
    'ON' => Switched.on,
    'OFF' => Switched.off,
    _ => Switched.off,
  };
}

enum Labeled {
  x('ex'), y('why');
  const Labeled(this.wire);
  final String wire;
  static Labeled parse(String v) => values.firstWhere((e) => e.wire == v);
}
''');

    test('wire values', () {
      expect(project.enums['Plain']!.values, ['one', 'two']);
      expect(project.enums['Annotated']!.values, ['first', 2]);
      expect(project.enums['Renamed']!.values, ['foo_bar', 'baz']);
      expect(project.enums['Coded']!.values, [200, 404]);
      expect(project.enums['Switched']!.values, ['ON', 'OFF']);
      expect(project.enums['Labeled']!.values, ['ex', 'why']);
    });

    test('safe parsers are detected', () {
      expect(project.enums['Switched']!.safeParse, isTrue);
      expect(project.enums['Labeled']!.safeParse, isFalse);
      expect(project.enums['Plain']!.safeParse, isFalse);
    });
  });

  group('project scan', () {
    test('reads build.yaml, skips generated files', () {
      final project = extractProject('test/fixtures/app');
      expect(
        project.models.keys,
        containsAll([
          'UserModel',
          'ProductModel',
          'SessionModel',
          'WalletModel',
          'AddressModel',
        ]),
      );
      final product = project.models['ProductModel']!;
      expect(product.file, 'lib/models/product_model.dart');
      expect(product.reads.map((r) => r.key), contains('product_id'));
      expect(product.reads.any((r) => r.key == 'should_not_be_read'), isFalse);
      expect(readGlobalFieldRename('test/fixtures/app'), FieldRename.snake);
    });

    test('exclude globs', () {
      final project = extractProject(
        'test/fixtures/app',
        exclude: ['lib/models/user_*.dart', '**/local_draft.dart'],
      );
      expect(project.models.containsKey('UserModel'), isFalse);
      expect(project.models.containsKey('LocalDraft'), isFalse);
      expect(project.models.containsKey('ProductModel'), isTrue);
    });
  });
}
