import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:myparty/services/party_links.dart';
import 'package:myparty/services/reset_request_store.dart';
import 'package:myparty/utils/auth_link.dart';

const _code = '56237d44-469d-4f57-9a17-633ff098517d';

void main() {
  group('authLinkFrom: reset', () {
    test('a PKCE code on the exact path is a ResetLink', () {
      final link = authLinkFrom(Uri.parse('$kResetRedirect?code=$_code'));
      expect(link, isA<ResetLink>());
      expect((link! as ResetLink).code, _code);
    });

    test('a link carrying any token is dropped, even with a valid code beside it', () {
      // The shape of a forged sign-in link. Nothing we send ever has it.
      for (final extra in [
        '#access_token=eyJ.x.y&refresh_token=r&token_type=bearer',
        '&access_token=eyJ.x.y',
        '&refresh_token=r',
        '&token_hash=abc',
        '#provider_token=p',
      ]) {
        expect(authLinkFrom(Uri.parse('$kResetRedirect?code=$_code$extra')), isNull, reason: extra);
      }
    });

    test('tokens alone on the reset path are dropped too', () {
      expect(authLinkFrom(Uri.parse('$kResetRedirect#access_token=eyJ.x.y&refresh_token=r')), isNull);
    });

    test("GoTrue's error redirect is a ResetLinkFailed", () {
      expect(
        authLinkFrom(Uri.parse('$kResetRedirect#error=access_denied&error_code=otp_expired&error_description=x')),
        isA<ResetLinkFailed>(),
      );
      expect(authLinkFrom(Uri.parse('$kResetRedirect?error=server_error')), isA<ResetLinkFailed>());
    });

    test('anything else is not a reset link', () {
      for (final s in [
        '$kResetRedirect?code=not-a-uuid',
        kResetRedirect,
        'http://mypartycorp.com/auth/reset?code=$_code',
        'https://www.mypartycorp.com/auth/reset?code=$_code',
        'https://mypartycorp.com:8443/auth/reset?code=$_code',
        'https://user@mypartycorp.com/auth/reset?code=$_code',
        'https://mypartycorp.com/auth/reset/extra?code=$_code',
        'https://mypartycorp.com/auth/callback?code=$_code',
        'https://evil.example/auth/reset?code=$_code',
      ]) {
        expect(authLinkFrom(Uri.parse(s)), isNull, reason: s);
      }
    });
  });

  group('authLinkFrom: email change', () {
    test("GoTrue's first-confirmation redirect says one address is confirmed", () {
      // Measured: the message rides in the query AND the fragment.
      final link = authLinkFrom(Uri.parse(
        '$kEmailChangeRedirect?message=Confirmation+link+accepted.+Please+proceed+to+confirm+link+sent+to+the+other+email'
        '#message=Confirmation+link+accepted.+Please+proceed+to+confirm+link+sent+to+the+other+email',
      ));
      expect(link, isA<EmailChangeLink>());
      expect((link! as EmailChangeLink).confirmedOne, isTrue);
    });

    test('the completing redirect is a plain EmailChangeLink, and its code is not read', () {
      final link = authLinkFrom(Uri.parse('$kEmailChangeRedirect?code=$_code')) as EmailChangeLink?;
      expect(link, isNotNull);
      expect(link!.confirmedOne, isFalse);
      expect(link.failed, isFalse);
    });

    test('an error redirect is a failed EmailChangeLink', () {
      final link = authLinkFrom(Uri.parse('$kEmailChangeRedirect#error=access_denied&error_code=otp_expired'));
      expect((link! as EmailChangeLink).failed, isTrue);
    });
  });

  test('party and invite links are not auth links', () {
    expect(authLinkFrom(Uri.parse('https://mypartycorp.com/p/aaaaaaaa-0000-0000-0000-000000000001')), isNull);
    expect(authLinkFrom(Uri.parse('https://mypartycorp.com/i#${'a' * 43}')), isNull);
  });

  group('PartyLinks.receive', () {
    setUp(() {
      PartyLinks.pending.value = null;
      PartyLinks.pendingInvite.value = null;
      PartyLinks.pendingAuth.value = null;
    });

    test('routes an auth link to pendingAuth and nowhere else', () {
      PartyLinks.receive(Uri.parse('$kResetRedirect?code=$_code'));
      expect(PartyLinks.pendingAuth.value, isA<ResetLink>());
      expect(PartyLinks.pending.value, isNull);
      expect(PartyLinks.pendingInvite.value, isNull);
    });

    test('drops a token-bearing auth link entirely', () {
      PartyLinks.receive(Uri.parse('$kResetRedirect#access_token=eyJ.x.y&refresh_token=r'));
      expect(PartyLinks.pendingAuth.value, isNull);
      expect(PartyLinks.pending.value, isNull);
      expect(PartyLinks.pendingInvite.value, isNull);
    });

    test('still routes party links', () {
      PartyLinks.receive(Uri.parse('https://mypartycorp.com/p/aaaaaaaa-0000-0000-0000-000000000001'));
      expect(PartyLinks.pending.value, 'aaaaaaaa-0000-0000-0000-000000000001');
      expect(PartyLinks.pendingAuth.value, isNull);
    });
  });

  group('ResetRequestStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('remembers the address for an hour, normalised', () async {
      var now = DateTime.utc(2026, 10, 21, 12);
      final store = ResetRequestStore(now: () => now);
      await store.record('  Ada@Example.com ');
      expect(await store.pendingEmail(), 'ada@example.com');

      now = now.add(const Duration(minutes: 59));
      expect(await store.pendingEmail(), 'ada@example.com');

      now = now.add(const Duration(minutes: 2));
      expect(await store.pendingEmail(), isNull, reason: 'past otp_expiry the link is dead anyway');
    });

    test('nothing recorded, or cleared, is null', () async {
      final store = ResetRequestStore();
      expect(await store.pendingEmail(), isNull);
      await store.record('ada@example.com');
      await store.clear();
      expect(await store.pendingEmail(), isNull);
    });
  });
}
