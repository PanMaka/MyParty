import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/utils/password.dart';

void main() {
  group('passwordError', () {
    test('accepts letters, digits and punctuation from 9 characters up', () {
      expect(passwordError('Party!Time9'), isNull);
      expect(passwordError('abcdefghi'), isNull);
      expect(passwordError(r'a-Z_9.@#$%^&*()[]{}<>?/\|~`"' "'"), isNull);
    });

    test('exactly 8 characters is too short, exactly 9 is enough', () {
      expect(passwordError('abcdefgh'), passwordTooShortMessage);
      expect(passwordError('abcdefgh!'), isNull);
    });

    test('a space anywhere is refused, and so is a letter outside a-z/A-Z', () {
      expect(passwordError('Party Time9'), passwordCharactersMessage);
      expect(passwordError(' PartyTime9'), passwordCharactersMessage);
      expect(passwordError('PartyTime9\t'), passwordCharactersMessage);
      expect(passwordError('Πάρτι!Time9'), passwordCharactersMessage);
      expect(passwordError('PartyTime9😀'), passwordCharactersMessage);
    });

    test('length is reported before the other rules', () {
      expect(passwordError('a b'), passwordTooShortMessage);
    });
  });

  group('hasPredictableDigits', () {
    test('three digits counting up, down or repeating are predictable', () {
      for (final p in ['Party!123x', 'x987Party', 'Party000!', 'a1b2345c', 'x0123', '1123']) {
        expect(hasPredictableDigits(p), isTrue, reason: p);
      }
    });

    test('two in a row, broken runs and unrelated digits are not', () {
      for (final p in ['Party!12x', 'Pa1rty2Ti3me', '135792468', '121', '1-2-3', '9 0 1', '890x']) {
        expect(hasPredictableDigits(p), isFalse, reason: p);
      }
    });
  });
}
