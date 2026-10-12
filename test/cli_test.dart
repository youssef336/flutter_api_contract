import 'dart:convert';
import 'dart:io';

import 'package:flutter_api_contract/flutter_api_contract.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<(int, String, String)> run(List<String> args) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await runCli(args, out: out, err: err);
  return (code, out.toString(), err.toString());
}

void main() {
  const app = 'test/fixtures/app';

  test('fixture app: drift found, exit 1, grouped text', () async {
    final (code, out, _) = await run(['-p', app]);
    expect(code, ExitCodes.drift);
    expect(out, contains('UserModel → User'));
    expect(out, contains('did you mean "user_name"?'));
    expect(out, contains('No drift: WalletModel → WalletDetails'));
    expect(out, contains('Skipped by config: CacheEntry'));
    expect(out, contains('8 errors · 7 warnings · 2 info'));
  });

  test('every finding code shows up on the fixture app', () async {
    final (_, out, _) = await run(['-p', app, '-f', 'json']);
    final doc = jsonDecode(out) as Map<String, Object?>;
    final codes = {
      for (final f in doc['findings']! as List) (f as Map)['code'],
    };
    expect(
      codes,
      containsAll([
        Codes.missingInSchema,
        Codes.requiredIgnored,
        Codes.nullableMismatch,
        Codes.typeMismatch,
        Codes.enumUnhandled,
        Codes.enumExtra,
        Codes.unmatchedModel,
      ]),
    );
    final models = {
      for (final m in doc['models']! as List) (m as Map)['model']: m['via'],
    };
    expect(models['WalletModel'], 'config');
    expect(models['ProfileModel'], 'endpoint');
    expect(models['SessionModel'], 'suffix');
  });

  test('--fail-on never / warning', () async {
    expect((await run(['-p', app, '--fail-on', 'never'])).$1, 0);
    final clean = await run([
      '-p',
      app,
      '--fail-on',
      'warning',
      '--spec',
      'test/fixtures/specs/openapi3.yaml',
    ]);
    expect(clean.$1, ExitCodes.drift);
  });

  group('baseline ratchet', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('cli'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('create, accept, then shrink but never grow', () async {
      final baseline = p.join(tmp.path, 'baseline.json');
      final created = await run([
        '-p',
        app,
        '-b',
        baseline,
        '--update-baseline',
      ]);
      expect(created.$1, ExitCodes.ok);
      expect(created.$3, contains('created with 17 entries'));
      expect(created.$2, contains('(17 baselined)'));

      // Drop two entries by hand: they come back as fresh findings.
      final doc = jsonDecode(File(baseline).readAsStringSync()) as Map;
      final entries = (doc['findings'] as List).cast<String>()
        ..removeWhere((e) => e.startsWith('nullable-mismatch|UserModel'));
      entries.add('type-mismatch|Fixed|gone');
      File(baseline).writeAsStringSync(jsonEncode({'findings': entries}));

      final checked = await run(['-p', app, '-b', baseline]);
      expect(checked.$1, ExitCodes.drift);
      expect(checked.$2, contains('1 error · 0 warnings · 0 info'));
      expect(checked.$2, contains('1 baseline entry is fixed'));

      final updated = await run([
        '-p',
        app,
        '-b',
        baseline,
        '--update-baseline',
      ]);
      expect(updated.$3, contains('17 → 16 entries'));
      expect(updated.$3, contains('1 new finding(s) not added'));
      expect(updated.$1, ExitCodes.drift);
    });
  });

  test('spec over http with headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? auth;
    server.listen((req) {
      auth = req.headers.value('authorization');
      req.response
        ..headers.contentType = ContentType.json
        ..write(File('test/fixtures/specs/swagger2.json').readAsStringSync())
        ..close();
    });
    addTearDown(() => server.close(force: true));
    final tmp = Directory.systemTemp.createTempSync('http');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Directory(p.join(tmp.path, 'lib')).createSync();
    File(p.join(tmp.path, 'lib', 'pet.dart')).writeAsStringSync('''
class PetModel {
  PetModel(this.name);
  factory PetModel.fromJson(Map<String, dynamic> json) =>
      PetModel(json['name'] as String);
  final String name;
}
''');
    final (code, out, _) = await run([
      '-p',
      tmp.path,
      '--spec',
      'http://127.0.0.1:${server.port}/docs-json',
      '-H',
      'Authorization: Bearer abc',
    ]);
    expect(auth, 'Bearer abc');
    expect(code, ExitCodes.ok);
    expect(out, contains('Swagger 2.0'));
    expect(out, contains('PetModel → Pet'));
  });

  test('usage errors exit 2', () async {
    final tmp = Directory.systemTemp.createTempSync('nospec');
    addTearDown(() => tmp.deleteSync(recursive: true));
    expect((await run(['-p', tmp.path])).$1, ExitCodes.usage);
    expect((await run(['--bogus'])).$1, ExitCodes.usage);
    expect(
      (await run(['-p', tmp.path, '--spec', 'missing.json'])).$1,
      ExitCodes.usage,
    );
    expect(
      (await run(['-p', tmp.path, '-c', 'nope.yaml', '--spec', 'x'])).$1,
      ExitCodes.usage,
    );
    expect((await run(['--help'])).$2, contains('Usage: api_contract'));
    expect((await run(['--version'])).$2, contains(packageVersion));
  });
}
