const _weekdayAbbr = ['Δευ', 'Τρί', 'Τετ', 'Πέμ', 'Παρ', 'Σάβ', 'Κυρ'];
const _monthAbbr = [
  'Ιαν', 'Φεβ', 'Μάρ', 'Απρ', 'Μάι', 'Ιούν',
  'Ιούλ', 'Αύγ', 'Σεπ', 'Οκτ', 'Νοέ', 'Δεκ',
];

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// "Απόψε 23:30" for today, otherwise "Σάβ 8 Αύγ, 23:30".
String formatPartyStart(DateTime startsAt) {
  final now = DateTime.now();
  final time = '${_twoDigits(startsAt.hour)}:${_twoDigits(startsAt.minute)}';
  if (startsAt.year == now.year && startsAt.month == now.month && startsAt.day == now.day) {
    return 'Απόψε $time';
  }
  final weekday = _weekdayAbbr[startsAt.weekday - 1];
  final month = _monthAbbr[startsAt.month - 1];
  return '$weekday ${startsAt.day} $month, $time';
}

/// "τώρα" / "12λ" / "5ω" / "3μ" / "8 Αύγ" — the age stamp on a feed post or
/// comment. Takes a UTC instant (`created_at` comes off the wire in UTC and
/// stays that way, because it doubles as the keyset cursor).
String formatPostAge(DateTime createdAt) {
  final elapsed = DateTime.now().toUtc().difference(createdAt.toUtc());

  if (elapsed.inMinutes < 1) return 'τώρα';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}λ';
  if (elapsed.inHours < 24) return '${elapsed.inHours}ω';
  if (elapsed.inDays < 7) return '${elapsed.inDays}μ';

  final local = createdAt.toLocal();
  return '${local.day} ${_monthAbbr[local.month - 1]}';
}
