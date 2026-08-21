/// The two party stamps the profile tab needs, in English.
///
/// A deliberate near-duplicate of `greek_date.dart`, not a replacement for it.
/// The rest of the app — the map, the feed, events, chat, the host wizard — is
/// still Greek, and a single formatter cannot be both; the alternative to two
/// files is one file with a locale argument threaded through every call site,
/// which is a localisation layer this app does not have yet. When it grows one,
/// these two functions and their Greek twins collapse into it.
///
/// Only the two the profile renders are here. `formatPostAge` has no English
/// caller, and writing one nothing uses would be a third copy to keep in sync
/// with a screen that does not exist.
const _weekdayAbbr = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _monthAbbr = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// "Tonight 23:30" for today, otherwise "Sat 8 Aug, 23:30".
///
/// 24-hour, like its Greek twin: the app's other times are, and one screen
/// switching to am/pm would make two stamps of the same party disagree.
String formatPartyStartEn(DateTime startsAt) {
  final now = DateTime.now();
  final time = '${_twoDigits(startsAt.hour)}:${_twoDigits(startsAt.minute)}';
  if (startsAt.year == now.year && startsAt.month == now.month && startsAt.day == now.day) {
    return 'Tonight $time';
  }
  final weekday = _weekdayAbbr[startsAt.weekday - 1];
  final month = _monthAbbr[startsAt.month - 1];
  return '$weekday ${startsAt.day} $month, $time';
}

/// "8 Sep" for a party earlier this year, "8 Sep 2025" for one before that —
/// the stamp on a party that has already happened.
///
/// Separate from [formatPartyStartEn] because that one says "Tonight" and
/// prints a clock time, both of which are answers to "when should I be there".
/// A party in the past is only ever being identified, not attended, so the year
/// matters and the minute does not.
String formatPartyPastEn(DateTime startsAt) {
  final month = _monthAbbr[startsAt.month - 1];
  final stamp = '${startsAt.day} $month';
  if (startsAt.year == DateTime.now().year) return stamp;
  return '$stamp ${startsAt.year}';
}
