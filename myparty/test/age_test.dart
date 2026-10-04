import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/utils/age.dart';

void main() {
  final today = DateTime(2026, 10, 3);

  test('turning 13 today counts', () {
    expect(isAtLeastAge(DateTime(2013, 10, 3), 13, today: today), isTrue);
  });

  test('turning 13 tomorrow does not', () {
    expect(isAtLeastAge(DateTime(2013, 10, 4), 13, today: today), isFalse);
  });

  test('time of day on the date of birth is ignored', () {
    expect(isAtLeastAge(DateTime(2013, 10, 3, 23, 59), 13, today: today), isTrue);
  });

  test('a 29 February birthday turns over on 1 March in a non-leap year', () {
    expect(isAtLeastAge(DateTime(2012, 2, 29), 13, today: DateTime(2025, 2, 28)), isFalse);
    expect(isAtLeastAge(DateTime(2012, 2, 29), 13, today: DateTime(2025, 3, 1)), isTrue);
  });

  test('on 29 February the cutoff clamps to 28 Feb, like Postgres', () {
    // '2024-02-29'::date - interval '13 years' = 2011-02-28.
    final leapDay = DateTime(2024, 2, 29);
    expect(isAtLeastAge(DateTime(2011, 2, 28), 13, today: leapDay), isTrue);
    expect(isAtLeastAge(DateTime(2011, 3, 1), 13, today: leapDay), isFalse);
  });

  test('form verdict: missing, under 13, and old enough', () {
    expect(dateOfBirthError(null, today: today), missingDateOfBirthMessage);
    expect(dateOfBirthError(DateTime(2013, 10, 4), today: today), underMinimumAgeMessage);
    expect(dateOfBirthError(DateTime(2013, 10, 3), today: today), isNull);
  });

  test('the under-13 message is the exact wording, matching the server', () {
    expect(underMinimumAgeMessage,
        'The Date Of Birth is not on par with the guidelines. You need to be 13+ to own a MyParty Account.');
  });

  test('isoDate is the YYYY-MM-DD shape the server parses', () {
    expect(isoDate(DateTime(2009, 1, 5)), '2009-01-05');
  });
}
