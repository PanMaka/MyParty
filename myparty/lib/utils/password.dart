/// Shortest password the register form accepts. The server enforces the same
/// number through `minimum_password_length` in supabase/config.toml; the other
/// two rules below exist only here, because GoTrue has no setting that
/// expresses them.
const minimumPasswordLength = 9;

const passwordTooShortMessage = 'The password must be at least 9 characters long';
const passwordCharactersMessage =
    'Only Lowercase, Uppercase letters, Numbers and Punctuation marks are allowed';
const passwordPatternMessage = 'Predictable patterns like "123" is not allowed';

/// Printable ASCII without the space: a-z, A-Z, 0-9 and punctuation.
final _allowedCharacters = RegExp(r'^[\x21-\x7E]*$');

/// Whether [password] contains three or more digits in a row that count up
/// ("123"), count down ("321") or repeat ("111").
bool hasPredictableDigits(String password) {
  var run = 1;
  int? step;
  int? previous;
  for (final unit in password.codeUnits) {
    final digit = unit >= 0x30 && unit <= 0x39 ? unit - 0x30 : null;
    if (digit == null) {
      run = 1;
      step = null;
      previous = null;
      continue;
    }
    if (previous != null) {
      final d = digit - previous;
      if (d.abs() <= 1 && (run == 1 || d == step)) {
        run++;
        step = d;
      } else {
        // The pair just read may still start a new run ("135" then "56...").
        run = d.abs() <= 1 ? 2 : 1;
        step = d.abs() <= 1 ? d : null;
      }
      if (run >= 3) return true;
    }
    previous = digit;
  }
  return false;
}

/// The register form's verdict on a password: null when acceptable, otherwise
/// the message for the first rule it breaks.
String? passwordError(String password) {
  if (password.length < minimumPasswordLength) return passwordTooShortMessage;
  if (!_allowedCharacters.hasMatch(password)) return passwordCharactersMessage;
  if (hasPredictableDigits(password)) return passwordPatternMessage;
  return null;
}
