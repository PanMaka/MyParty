/// Which time window the map is asking the server for — the Όλα / Τώρα /
/// Αργότερα απόψε / Το ΣΚ chips.
///
/// **These are the only four values `get_parties_near_user`'s `p_window`
/// accepts, and the server RAISES on anything else** rather than falling back
/// to "everything" (`20260823091942`). That is deliberate on both sides: a
/// silent fallback would draw a full map underneath a highlighted chip, which
/// reads as a broken filter with nothing anywhere to say so. The enum is what
/// makes an invalid value unrepresentable here, so the raise is a contract and
/// not an error path anyone should ever see.
///
/// **The window is applied in the query, never to the fetched list.** Filtering
/// `_pins` in Dart would make "Τώρα" mean "whatever happened to be in the last
/// viewport fetch" — which is a different, worse feature that happens to look
/// identical on a screen with six pins on it. It also throws away the entire
/// point: the time terms are leakproof and are evaluated *before* the row
/// policy, so filtering server-side makes the query cheaper rather than merely
/// moving the work (CLAUDE.md gotcha 22).
///
/// What each window MEANS — the local-calendar boundaries — is defined once, in
/// `public.party_time_window()`, and deliberately not restated here. Tonight
/// runs to the next local 04:00 rather than midnight; the weekend is Friday
/// 18:00 to Monday 04:00 and clamps to now when it is already the weekend.
/// Reimplementing either in Dart would give the app a second calendar that
/// disagrees with the database twice a year, at the DST boundary, which lands
/// at exactly 04:00 local in Greece.
enum MapTimeWindow {
  /// No time bound at all, and the default — the map behaves exactly as it did
  /// before the chips existed. Like every window, it drops a party with no
  /// stated `ends_at` once the server's six-hour grace has passed, the same
  /// rule ALL PARTIES uses (CLAUDE.md gotcha 21).
  all('all'),

  /// Already started and not over. The only window that looks backwards, and
  /// so the only one that has to think about a null `ends_at` beyond the
  /// shared rule: past the server's six-hour grace it is off the map entirely.
  now('now'),

  /// Starts between now and the next local 04:00.
  tonight('tonight'),

  /// Starts inside the coming (or current) weekend.
  weekend('weekend');

  const MapTimeWindow(this.wire);

  /// The literal the RPC expects. Kept separate from the Dart name so
  /// renaming the enum cannot silently change the wire contract.
  final String wire;
}
