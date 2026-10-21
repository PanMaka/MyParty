/// What the emailed-code flows say (Phase 47): sign-up confirmation, Forgot
/// password, Change email and the links. One file, so the screens, the link
/// handler and the tests cannot drift apart.
library;

const confirmEmailTitle = 'Confirm your email';

String codeSentTo(String email) => 'We sent an 8-digit code to $email. It expires in an hour.';

/// GoTrue answers a wrong, used, superseded and expired code with one error,
/// so the message covers all four.
const codeWrongOrExpiredMessage = 'That code is wrong or has expired. Check the newest email, or send a new code.';

const tooManyAttemptsMessage = 'Too many attempts. Wait a few minutes and try again.';

const somethingWentWrongMessage = 'Something went wrong. Check your connection and try again.';

const invalidEmailMessage = 'Enter a valid email address';

const codeLengthMessage = 'The code has 8 digits';

String codeResentTo(String email) => 'A new code is on its way to $email.';

// Forgot password.

const forgotPasswordTitle = 'Reset your password';

/// The same sentence whether or not the address has an account, because the
/// server answers the same (measured): the screen must not be the oracle.
String resetCodeSentTo(String email) => "If there's an account for $email, we've sent it an 8-digit code.";

const resetLinkHint = 'On Android you can also tap the link in that email, on this phone.';

const newPasswordTitle = 'Choose a new password';

const resetLinkNotRequestedHere =
    'That reset link was asked for on another phone, or more than an hour ago. Ask for a new one here.';

const resetLinkExpiredMessage =
    'That link has expired or was already used. Use the code in the email, or ask for a new one.';

// Change email.

String emailChangeCodesSent(String current, String next) =>
    'We sent a code to $current and a code to $next. Enter both to finish: nothing changes until both are confirmed.';

const emailChangeWaitingMessage = 'Confirmed. Now enter the code sent to the other address.';

String emailChangedMessage(String email) => 'Your email is now $email.';

const emailTakenByOtherMessage = 'That email is already used by another account';

const sameEmailMessage = "That's already your email";

const emailChangeConfirmedHint = 'If you already confirmed this address, enter the code sent to the other one.';

// The email-change link, handled by AuthLinkHandler.

const emailChangeLinkConfirmedOne = 'Confirmed. Now confirm from your other inbox.';

const emailChangeLinkFailed = 'That link has expired or was already used. Use the code in the email instead.';

const emailChangeLinkSignedOut = 'Confirmed. Sign in to see your new email.';
