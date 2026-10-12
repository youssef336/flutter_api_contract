import 'package:flutter_api_contract/flutter_api_contract.dart';
import 'package:test/test.dart';

/// End to end against the public Swagger Petstore v3 spec (vendored copy,
/// Apache-2.0) and a small app with three deliberate drifts.
void main() {
  test('finds exactly the three planted drifts', () async {
    final out = StringBuffer();
    final code = await runCli(
      [
        '-p',
        'test/fixtures/petstore_app',
        '--spec',
        'test/fixtures/specs/petstore3.json',
      ],
      out: out,
      err: StringBuffer(),
    );
    final text = out.toString();
    expect(code, ExitCodes.drift);
    expect(text, contains('OpenAPI 3.0.4'));
    expect(text, contains('did you mean "photoUrls"?'));
    expect(text, contains('"name" is not required in Category'));
    expect(text, contains('does not know "delivered"'));
    expect(text, contains('3 errors · 0 warnings · 1 info'));
  });
}
