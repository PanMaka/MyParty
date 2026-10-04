/// Minimum age to own an account. The server enforces the same number in the
/// `before_user_created_age_gate` Auth hook (20261003143423_date_of_birth.sql);
/// this copy only exists so the form can say no before a request is sent.
const minimumAccountAge = 13;

/// Whether someone born on [dob] is at least [years] old on [today] (default:
/// now). Calendar-exact: turning [years] today counts. A 29 February birthday
/// turns over on 1 March in non-leap years, matching Postgres's
/// `current_date - interval 'N years'`.
bool isAtLeastAge(DateTime dob, int years, {DateTime? today}) {
  final now = today ?? DateTime.now();
  final year = now.year - years;
  // Clamp like Postgres: 29 Feb minus N years is 28 Feb, not (as Dart's
  // DateTime would roll it) 1 Mar.
  final lastDay = DateTime(year, now.month + 1, 0).day;
  final cutoff = DateTime(year, now.month, now.day > lastDay ? lastDay : now.day);
  final birth = DateTime(dob.year, dob.month, dob.day);
  return !birth.isAfter(cutoff);
}

/// Word for word what the server's age gate returns, so the user reads the
/// same sentence whichever side refuses.
const underMinimumAgeMessage =
    'The Date Of Birth is not on par with the guidelines. You need to be 13+ to own a MyParty Account.';
const missingDateOfBirthMessage = 'Please enter your date of birth.';

/// The registration form's verdict on a date of birth: null when acceptable,
/// otherwise the message to show under the field.
String? dateOfBirthError(DateTime? dob, {DateTime? today}) {
  if (dob == null) return missingDateOfBirthMessage;
  if (!isAtLeastAge(dob, minimumAccountAge, today: today)) return underMinimumAgeMessage;
  return null;
}

/// `YYYY-MM-DD`, the only shape the server's parser accepts.
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
