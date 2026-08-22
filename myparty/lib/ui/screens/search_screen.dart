import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/party_repository.dart';
import '../../data/social_repository.dart';
import '../../models/map_party_pin.dart';
import '../../models/profile.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/map_pin_sheet.dart';
import 'profile_screen.dart';

/// Unified search over people and parties.
///
/// Two RPCs, one screen. They are kept as two calls rather than one union
/// because they answer different questions with different visibility rules —
/// `search_profiles` is gated by the `profiles` block filter, `search_parties`
/// by `can_access_party` — and merging them server-side would have meant one
/// function reasoning about both.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.social, this.parties});

  /// Injectable so widget tests can subclass the repositories without a
  /// Supabase client existing, the same seam every other screen here uses.
  final SocialRepository? social;
  final PartyRepository? parties;

  /// Nothing is sent until the query is at least this long.
  ///
  /// This is a UX constraint standing in for a database one, and it is
  /// deliberate. `search_parties` is uncapped: it returns every match a viewer
  /// can see, in the right order, however many that is. Capping it in SQL would
  /// bound the cost by silently returning a subset — which is the failure mode
  /// the whole search phase was built to avoid (see
  /// `docs/phase-14-text-search.md` §5b).
  ///
  /// So the restraint lives here instead. Measured at 10k parties: a query
  /// matching one party costs 2ms, one matching a third of them costs 295ms.
  /// Two characters is the second case, and it is not a search anybody wants —
  /// `τα` tells you nothing. Three characters is the first case.
  ///
  /// Any other client can ignore this, and that is accepted: bypassing it makes
  /// a query SLOW, not WRONG.
  static const int minQueryLength = 3;

  /// Long enough that typing a word does not fire four queries, short enough
  /// that the results feel attached to the keyboard.
  static const Duration debounce = Duration(milliseconds: 300);

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final SocialRepository _social = widget.social ?? SocialRepository();
  late final PartyRepository _parties = widget.parties ?? PartyRepository();

  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  /// The query the in-flight request was issued for. A slow response for an
  /// older query must not overwrite a newer one's results — without this,
  /// deleting characters quickly can leave the screen showing hits for a
  /// prefix that is no longer in the box.
  String _inFlightFor = '';

  String _query = '';
  bool _loading = false;
  Object? _error;
  List<Profile> _people = const [];
  PartySearchResults _partyHits = const PartySearchResults(upcoming: [], past: []);

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    final query = raw.trim();
    setState(() => _query = query);

    _debounce?.cancel();
    if (query.length < SearchScreen.minQueryLength) {
      // Drop anything already fetched: leaving the previous results on screen
      // under a two-character query reads as "these are the matches for `τα`".
      setState(() {
        _loading = false;
        _error = null;
        _people = const [];
        _partyHits = const PartySearchResults(upcoming: [], past: []);
      });
      return;
    }

    _debounce = Timer(SearchScreen.debounce, () => _run(query));
  }

  Future<void> _run(String query) async {
    setState(() {
      _loading = true;
      _error = null;
      _inFlightFor = query;
    });

    try {
      final results = await Future.wait([
        _social.searchProfiles(query),
        _parties.searchParties(query),
      ]);
      if (!mounted || _inFlightFor != query) return;
      setState(() {
        _people = results[0] as List<Profile>;
        _partyHits = results[1] as PartySearchResults;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || _inFlightFor != query) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _openProfile(Profile profile) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProfileScreen(target: OtherProfile(profile.id)),
    ));
  }

  /// The same sheet the map opens, deliberately. `search_parties` returns
  /// `lat`/`lon` so a hit is a [MapPartyPin], which means the report action and
  /// the live attendee count behave identically whether the party was reached
  /// from a pin or from a search result.
  void _openParty(MapPartyPin pin) => showMapPinSheet(context, pin);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _searchField(),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back, size: 20, color: AppColors.text),
            tooltip: 'Πίσω',
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                color: AppColors.chipFill,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Row(
                children: [
                  Icon(Icons.search, size: 16, color: AppColors.textAlpha(0.5)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      onChanged: _onChanged,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(fontSize: 13.5, color: AppColors.text),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Ψάξε πάρτι ή άτομα',
                        hintStyle: TextStyle(fontSize: 13.5, color: AppColors.textAlpha(0.5)),
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _controller.clear();
                        _onChanged('');
                      },
                      child: Icon(Icons.close, size: 16, color: AppColors.textAlpha(0.5)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_query.length < SearchScreen.minQueryLength) {
      return _hint(
        icon: Icons.keyboard_alt_outlined,
        title: 'Γράψε κι άλλο',
        detail: 'Χρειάζονται τουλάχιστον ${SearchScreen.minQueryLength} χαρακτήρες '
            'για να ξεκινήσει η αναζήτηση.',
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.purple));
    }
    if (_error != null) {
      return _hint(
        icon: Icons.cloud_off,
        title: 'Κάτι πήγε στραβά',
        detail: 'Δεν μπορέσαμε να ολοκληρώσουμε την αναζήτηση. Δοκίμασε ξανά.',
      );
    }
    if (_people.isEmpty && _partyHits.isEmpty) {
      return _hint(
        icon: Icons.search_off,
        title: 'Κανένα αποτέλεσμα',
        detail: 'Δεν βρέθηκε πάρτι ή άτομο για «$_query». '
            'Η αναζήτηση ξεκινάει από την αρχή της λέξης.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
      children: [
        if (_people.isNotEmpty) ...[
          _sectionTitle('Άτομα'),
          for (final p in _people) _personTile(p),
        ],
        if (_partyHits.upcoming.isNotEmpty) ...[
          _sectionTitle('Επερχόμενα'),
          for (final pin in _partyHits.upcoming) _partyTile(pin, past: false),
        ],
        // Past parties are shown, not hidden: "find that party from May" is a
        // real use. The split comes from the server's party_is_past(), not from
        // a second opinion computed here.
        if (_partyHits.past.isNotEmpty) ...[
          _sectionTitle('Πέρασαν'),
          for (final pin in _partyHits.past) _partyTile(pin, past: true),
        ],
      ],
    );
  }

  Widget _sectionTitle(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
      child: Text(
        label,
        style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.55)),
      ),
    );
  }

  Widget _personTile(Profile profile) {
    return GestureDetector(
      onTap: () => _openProfile(profile),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: DiagonalStripePlaceholder(
                borderRadius: BorderRadius.circular(19),
                colors: const [Color(0xFF2A2247), Color(0xFF1E1836)],
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile.username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('${profile.followerCount} ακόλουθοι',
                      style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.55))),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: AppColors.textAlpha(0.35)),
          ],
        ),
      ),
    );
  }

  Widget _partyTile(MapPartyPin pin, {required bool past}) {
    final accent = pin.isPrivate ? AppColors.pink : AppColors.purple;
    return GestureDetector(
      onTap: () => _openParty(pin),
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        // Past parties stay legible but read as archive rather than as
        // something to go to tonight.
        opacity: past ? 0.62 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: DiagonalStripePlaceholder(
                  borderRadius: BorderRadius.circular(11),
                  colors: pin.isPrivate
                      ? const [Color(0xFF2C1F2A), Color(0xFF20161F)]
                      : const [Color(0xFF2A2247), Color(0xFF1E1836)],
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pin.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            pin.area ?? (pin.isPrivate ? 'Ιδιωτικό' : 'Δημόσιο'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.mono(
                              size: 9,
                              color: pin.isPrivate ? AppColors.pinkLight : AppColors.purpleLight,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: AppColors.textAlpha(0.35)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hint({required IconData icon, required String title, required String detail}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: AppColors.textAlpha(0.3)),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(detail,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.textAlpha(0.55))),
          ],
        ),
      ),
    );
  }
}
