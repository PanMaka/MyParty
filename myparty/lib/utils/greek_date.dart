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
