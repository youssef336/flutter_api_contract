import 'package:flutter_api_contract/flutter_api_contract.dart';
import 'package:test/test.dart';

/// Regression tests for false positives seen on generated (NestJS) specs.
/// Each group pairs a "still catches the real drift" case with a "no false
/// positive" case.

ContractChecker checker(
  String dart,
  String specText, {
  ContractConfig? config,
}) => ContractChecker(
  project: extractFromSources({'lib/m.dart': dart}),
  spec: parseSpecText(specText),
  config: config ?? ContractConfig(),
);

List<Finding> check(String dart, String specText) =>
    checker(dart, specText).check();

List<Finding> errors(List<Finding> findings) =>
    findings.where((f) => f.severity == Severity.error).toList();

Finding? find(List<Finding> findings, String code, [String? key]) {
  for (final f in findings) {
    if (f.code == code && (key == null || f.key == key)) return f;
  }
  return null;
}

void main() {
  group('bare {type: object} is unknown, not an object', () {
    const spec = '''
openapi: 3.0.0
components:
  schemas:
    Banner:
      type: object
      required: [id]
      properties:
        id: {type: integer}
        title: {type: object, nullable: true, example: Hello}
        shownAt: {type: object, description: string | null}
        count: {type: object}
        meta: {type: object, additionalProperties: {type: string}}
        name: {type: string}
''';

    test('parses as any, keeping nullability', () {
      final banner = parseSpecText(spec).schemas['Banner']!;
      expect(banner.properties['title']!.type, JsonType.any);
      expect(banner.properties['title']!.nullable, isTrue);
      expect(banner.properties['meta']!.type, JsonType.object);
      final v31 = parseSchema({
        'type': ['object', 'null'],
      });
      expect(v31.type, JsonType.any);
      expect(v31.nullable, isTrue);
    });

    test('String/DateTime/int reads of a bare object are not mismatches', () {
      final findings = check('''
class Banner {
  Banner(this.id, this.title, this.shownAt, this.count);
  factory Banner.fromJson(Map<String, dynamic> json) => Banner(
    json['id'] as int,
    json['title'] as String?,
    json['shownAt'] == null ? null : DateTime.parse(json['shownAt'] as String),
    json['count'] as int?,
  );
  final int id;
  final String? title;
  final DateTime? shownAt;
  final int? count;
}''', spec);
      expect(find(findings, Codes.typeMismatch), isNull);
    });

    test('a real type change and a typed object still mismatch', () {
      final findings = check('''
class Banner {
  Banner(this.id, this.meta, this.name);
  factory Banner.fromJson(Map<String, dynamic> json) =>
      Banner(json['id'] as String, json['meta'] as String?, json['name'] as int?);
  final String id;
  final String? meta;
  final int? name;
}''', spec);
      expect(
        find(findings, Codes.typeMismatch, 'id')!.severity,
        Severity.error,
      );
      expect(find(findings, Codes.typeMismatch, 'meta'), isNotNull);
      expect(find(findings, Codes.typeMismatch, 'name'), isNotNull);
    });
  });

  group('enums with their own fallback parser', () {
    const spec = '''
openapi: 3.0.0
components:
  schemas:
    Account:
      type: object
      required: [status]
      properties:
        status: {type: string, enum: [LINKED, ENDED, PAUSED]}
''';
    String account(String enumSource) =>
        '''
$enumSource
class Account {
  Account(this.status);
  factory Account.fromJson(Map<String, dynamic> json) =>
      Account(Status.fromJson(json['status'] as String?));
  final Status status;
}''';

    test('ternary with a default constant: info, case-insensitive', () {
      final findings = check(
        account('''
enum Status {
  linked,
  ended;

  static Status fromJson(String? raw) =>
      raw?.toUpperCase() == 'ENDED' ? Status.ended : Status.linked;
}'''),
        spec,
      );
      final f = find(findings, Codes.enumUnhandled, 'status')!;
      expect(f.severity, Severity.info);
      // LINKED / ENDED match linked / ended; only PAUSED is unknown.
      expect(f.message, contains('"PAUSED"'));
      expect(f.message, isNot(contains('LINKED')));
      expect(find(findings, Codes.enumExtra), isNull);
      expect(errors(findings), isEmpty);
    });

    test(
      'block body ending in return, firstWhere(orElse:), switch default',
      () {
        for (final source in [
          '''
enum Status {
  linked, ended, paused;
  static Status fromJson(String? raw) {
    if (raw == 'ENDED') return Status.ended;
    return Status.linked;
  }
}''',
          '''
enum Status {
  linked, ended;
  static Status fromJson(String? raw) => Status.values.firstWhere(
      (s) => s.name == raw?.toLowerCase(), orElse: () => Status.linked);
}''',
          '''
enum Status {
  linked, ended;
  static Status fromJson(String? raw) {
    switch (raw?.toUpperCase()) {
      case 'ENDED': return Status.ended;
      default: return Status.linked;
    }
  }
}''',
        ]) {
          final findings = check(account(source), spec);
          expect(errors(findings), isEmpty, reason: source);
        }
      },
    );

    test('a parser without a fallback is still a crash risk', () {
      final findings = check(
        account('''
enum Status {
  linked, ended;
  static Status fromJson(String? raw) => Status.values.byName(raw!);
}'''),
        spec,
      );
      final f = find(findings, Codes.enumUnhandled, 'status')!;
      expect(f.severity, Severity.error);
      expect(f.message, contains('CRASH RISK'));
    });

    test('case differences count without upper/lower-casing', () {
      final findings = check(
        account('''
enum Status {
  linked, ended, paused;
  static Status fromJson(String? raw) => Status.values.byName(raw!);
}'''),
        spec,
      );
      expect(find(findings, Codes.enumUnhandled, 'status'), isNotNull);
    });
  });

  group('type-guarded reads', () {
    const spec = '''
openapi: 3.0.0
components:
  schemas:
    Invite:
      type: object
      required: [id]
      properties:
        id: {type: integer}
        note: {type: string}
        logo: {type: string, nullable: true}
        expiresAt: {type: string, format: date-time}
        label: {type: string}
''';

    test('is Map / is! Map / != null guards do not throw', () {
      final findings = check('''
class Invite {
  Invite(this.id, this.note, this.logo, this.expiresAt, this.label);
  factory Invite.fromJson(Map<String, dynamic> json) {
    String? logo;
    if (json['logo'] is Map) {
      logo = (json['logo'] as Map)['name'] as String?;
    } else {
      logo = json['logo'] as String?;
    }
    return Invite(
      json['id'] as int,
      json['note'] is Map && (json['note'] as Map).isEmpty
          ? null
          : json['note'] as String?,
      logo,
      json['expiresAt'] != null && json['expiresAt'] is! Map
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
      json['label'] != null ? json['label'] as String : 'none',
    );
  }
  final int id;
  final String? note;
  final String? logo;
  final DateTime? expiresAt;
  final String label;
}''', spec);
      expect(find(findings, Codes.nullableMismatch), isNull);
      expect(find(findings, Codes.typeMismatch), isNull);
    });

    test('unguarded reads of the same shapes are still flagged', () {
      final findings = check('''
class Invite {
  Invite(this.id, this.note, this.logo, this.label);
  factory Invite.fromJson(Map<String, dynamic> json) => Invite(
    json['id'] as int,
    json['note'] as Map?,
    (json['logo'] as Map)['name'] as String?,
    json['label'] as String,
  );
  final int id;
  final Map? note;
  final String? logo;
  final String label;
}''', spec);
      expect(find(findings, Codes.typeMismatch, 'note'), isNotNull);
      expect(find(findings, Codes.nullableMismatch, 'logo'), isNotNull);
      expect(find(findings, Codes.typeMismatch, 'logo'), isNotNull);
      expect(find(findings, Codes.nullableMismatch, 'label'), isNotNull);
    });
  });

  group('model/schema pairing', () {
    const spec = '''
openapi: 3.0.0
paths:
  /vibes:
    post:
      requestBody:
        content:
          application/json:
            schema: {\$ref: '#/components/schemas/CreateVibeDto'}
      responses:
        '201':
          content:
            application/json:
              schema: {\$ref: '#/components/schemas/CreateVibeResponseDto'}
  /stats:
    get:
      responses:
        '200':
          content:
            application/json:
              schema:
                type: object
                properties:
                  user: {\$ref: '#/components/schemas/UserLiveStatsDto'}
                  live: {\$ref: '#/components/schemas/LiveStatsDto'}
  /prefs:
    get:
      responses:
        '200':
          content:
            application/json:
              schema: {\$ref: '#/components/schemas/PreferencesResponseDto'}
    put:
      requestBody:
        content:
          application/json:
            schema: {\$ref: '#/components/schemas/NotificationPreferencesDto'}
      responses:
        '200': {description: ok}
components:
  schemas:
    CreateVibeDto:
      type: object
      properties: {title: {type: string}, caption: {type: string}}
    CreateVibeResponseDto:
      type: object
      required: [id, status]
      properties: {id: {type: integer}, status: {type: string}}
    LiveStatsDto:
      type: object
      required: [viewerCount, totalViewers, peakViewers]
      properties:
        viewerCount: {type: integer}
        totalViewers: {type: integer}
        peakViewers: {type: integer}
    UserLiveStatsDto:
      type: object
      required: [totalLives, totalViewers, averageViewers, totalHoursLive]
      properties:
        totalLives: {type: integer}
        totalViewers: {type: integer}
        averageViewers: {type: number}
        totalHoursLive: {type: number}
    NotificationPreferencesDto:
      type: object
      properties: {likes: {type: boolean}, follows: {type: boolean}}
    PreferencesResponseDto:
      type: object
      required: [preferences]
      properties:
        preferences:
          type: object
          properties: {likes: {type: boolean}, follows: {type: boolean}}
        quietHours: {type: object, properties: {start: {type: string}}}
''';

    ModelMatch matchOf(String dart, String model) => checker(
      dart,
      spec,
    ).match.matches.firstWhere((m) => m.model.name == model);

    test('XResponse pairs with XResponseDto, never the request DTO', () {
      const dart = '''
class CreateVibeResponse {
  CreateVibeResponse(this.id, this.status);
  factory CreateVibeResponse.fromJson(Map<String, dynamic> json) =>
      CreateVibeResponse(json['id'] as int, json['statsu'] as String);
  final int id;
  final String status;
}''';
      expect(
        matchOf(dart, 'CreateVibeResponse').schemaName,
        'CreateVibeResponseDto',
      );
      // A real rename is still an error against the right schema.
      final f = find(check(dart, spec), Codes.missingInSchema, 'statsu')!;
      expect(f.severity, Severity.error);
      expect(f.suggestion, contains('"status"'));
    });

    test('a request-only namesake alone leaves the model unmatched', () {
      final m = checker('''
class CreateVibe {
  CreateVibe(this.title);
  factory CreateVibe.fromJson(Map<String, dynamic> json) =>
      CreateVibe(json['title'] as String);
  final String title;
}''', spec).match;
      expect(m.matches, isEmpty);
      expect(m.unmatched.keys.single.name, 'CreateVibe');
    });

    test('low overlap re-pairs with the schema that has every key', () {
      const dart = '''
class LiveStatsModel {
  LiveStatsModel(this.a, this.b, this.c, this.d);
  factory LiveStatsModel.fromJson(Map<String, dynamic> json) => LiveStatsModel(
    json['totalLives'] as int,
    json['totalViewers'] as int,
    (json['averageViewers'] as num).toDouble(),
    (json['totalHoursLive'] as num).toDouble(),
  );
  final int a;
  final int b;
  final double c;
  final double d;
}''';
      final m = matchOf(dart, 'LiveStatsModel');
      expect(m.schemaName, 'UserLiveStatsDto');
      expect(m.via, MatchVia.shape);
      final findings = check(dart, spec);
      expect(errors(findings), isEmpty);
      expect(find(findings, Codes.ambiguousMatch)!.severity, Severity.info);
    });

    test('a wrapper read pairs with the response, not the request DTO', () {
      final m = matchOf('''
class NotificationPreferencesModel {
  NotificationPreferencesModel(this.likes, this.follows, this.start);
  factory NotificationPreferencesModel.fromJson(Map<String, dynamic> json) {
    final prefs = json['preferences'] as Map<String, dynamic>;
    return NotificationPreferencesModel(
      prefs['likes'] as bool?,
      prefs['follows'] as bool?,
      json['quietHours']?['start'] as String?,
    );
  }
  final bool? likes;
  final bool? follows;
  final String? start;
}''', 'NotificationPreferencesModel');
      expect(m.schemaName, 'PreferencesResponseDto');
      expect(m.via, MatchVia.shape);
    });

    test('low overlap with no better schema: missing keys become info', () {
      final findings = check('''
class LiveStatsModel {
  LiveStatsModel(this.a, this.b, this.c, this.d);
  factory LiveStatsModel.fromJson(Map<String, dynamic> json) => LiveStatsModel(
    json['success'] as bool,
    json['message'] as String,
    json['data'] as Map<String, dynamic>,
    json['totalViewers'] as int,
  );
  final bool a;
  final String b;
  final Map<String, dynamic> c;
  final int d;
}''', spec);
      expect(errors(findings), isEmpty);
      expect(find(findings, Codes.ambiguousMatch), isNotNull);
      expect(
        find(findings, Codes.missingInSchema, 'success')!.severity,
        Severity.info,
      );
    });

    test('a rename with good overlap is still an error', () {
      final findings = check('''
class LiveStatsModel {
  LiveStatsModel(this.a, this.b, this.c);
  factory LiveStatsModel.fromJson(Map<String, dynamic> json) => LiveStatsModel(
    json['viewerCount'] as int,
    json['totalViewers'] as int,
    json['peakViewer'] as int,
  );
  final int a;
  final int b;
  final int c;
}''', spec);
      expect(find(findings, Codes.ambiguousMatch), isNull);
      expect(
        find(findings, Codes.missingInSchema, 'peakViewer')!.severity,
        Severity.error,
      );
    });
  });
}
