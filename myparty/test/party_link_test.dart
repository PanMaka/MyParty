import 'package:flutter_test/flutter_test.dart';
import 'package:myparty/utils/party_link.dart';

void main() {
  const id = '3f2a9c1e-7b4d-4e8a-9c2f-1d5e6a7b8c90';

  test('builds https://mypartycorp.com/p/<id>', () {
    expect(partyLink(id).toString(), 'https://mypartycorp.com/p/$id');
  });

  test('round-trips its own links', () {
    expect(partyIdFromLink(partyLink(id)), id);
  });

  group('accepts', () {
    for (final link in [
      'https://mypartycorp.com/p/$id',
      'https://mypartycorp.com/p/$id/',
      'https://mypartycorp.com:443/p/$id',
    ]) {
      test(link, () => expect(partyIdFromLink(Uri.parse(link)), id));
    }
  });

  group('ignores what rides along, rather than acting on it', () {
    // The login-CSRF shape from the Phase 25 review: session tokens in the
    // fragment. The party still opens; the tokens are never read here, and
    // main.dart turns off the one thing that would read them.
    for (final link in [
      'https://mypartycorp.com/p/$id#access_token=x&refresh_token=y&expires_in=3600&token_type=bearer',
      'https://mypartycorp.com/p/$id?code=abc',
      'https://mypartycorp.com/p/$id?invite=1&as=admin',
    ]) {
      test(link, () => expect(partyIdFromLink(Uri.parse(link)), id));
    }
  });

  group('refuses', () {
    for (final link in [
      'http://mypartycorp.com/p/$id', // not https
      'myparty://p/$id', // a custom scheme any app can claim
      'https://evil.com/p/$id',
      'https://mypartycorp.com.evil.com/p/$id', // suffix trick
      'https://evilmypartycorp.com/p/$id',
      'https://www.mypartycorp.com/p/$id', // the manifest verifies the apex only
      'https://user@mypartycorp.com/p/$id', // userinfo
      'https://mypartycorp.com:8443/p/$id',
      'https://mypartycorp.com/p/${id.toUpperCase()}',
      'https://mypartycorp.com/p/not-a-uuid',
      'https://mypartycorp.com/p/$id/edit', // extra segment
      'https://mypartycorp.com/x/$id',
      'https://mypartycorp.com/p/',
      'https://mypartycorp.com/',
      'https://mypartycorp.com/p/..%2F$id',
    ]) {
      test(link, () => expect(partyIdFromLink(Uri.parse(link)), isNull));
    }
  });
}
