import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/social_repository.dart';
import '../../models/profile.dart';
import '../../services/auth_service.dart';
import '../../state/mp_store.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/follow_button.dart';
import '../widgets/party_detail_sheet.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.userId});

  /// Whose profile this is. Null means "no real profile selected", which is
  /// how `main_screen.dart` mounts it on the tab bar today — the public view
  /// then keeps its design-prototype strings, because nothing in the app
  /// navigates to another user yet (that arrives with search, Phase 8).
  final String? userId;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _social = SocialRepository();

  bool _selfView = true;
  Future<List<Profile>>? _theirFollowing;

  @override
  void initState() {
    super.initState();
    final id = widget.userId;
    if (id != null) _theirFollowing = _social.fetchFollowing(userId: id);
  }

  void _comingSoon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Έρχεται σύντομα'), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MpStore>();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Προφίλ', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(99)),
                    child: Row(
                      children: [
                        _segment('ΕΓΩ', _selfView, () => setState(() => _selfView = true)),
                        _segment('ΔΗΜΟΣΙΑ', !_selfView, () => setState(() => _selfView = false)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Row(
                children: [
                  Container(
                    width: 74,
                    height: 74,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.purple.withValues(alpha: 0.5), width: 2)),
                    child: const DiagonalStripePlaceholder(colors: [Color(0xFF241E3C), Color(0xFF1B1630)], label: 'avatar'),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Κατερίνα Βλάχου', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                        Text('@katerina · ΕΚΠΑ, Ψυχολογία', style: TextStyle(fontSize: 12.5, color: AppColors.textAlpha(0.5))),
                        Padding(
                          padding: const EdgeInsets.only(top: 9),
                          child: Row(
                            children: [
                              _countPair('184', 'φίλοι'),
                              const SizedBox(width: 16),
                              _countPair('23', 'ακολουθεί'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  Expanded(child: _statTile('47', 'πάρτι φέτος')),
                  const SizedBox(width: 8),
                  Expanded(child: _statTile('5', 'διοργάνωσε', pink: true)),
                  const SizedBox(width: 8),
                  Expanded(child: _statTile('312', 'stories')),
                ],
              ),
            ),
            if (_selfView) ..._selfSections(context, store) else ..._publicSections(context, store),
          ],
        ),
      ),
    );
  }

  List<Widget> _selfSections(BuildContext context, MpStore store) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
            const SizedBox(height: 9),
            GestureDetector(
              onTap: () => showPartyDetailSheet(context, 'taratsa'),
              child: Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: AppColors.pink.withValues(alpha: 0.28)),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppColors.pink.withValues(alpha: 0.14), Colors.white.withValues(alpha: 0.03)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Ταράτσα στο Κουκάκι', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                            SizedBox(height: 2),
                            Text('Απόψε · 18/24 δέχτηκαν', style: TextStyle(fontSize: 11.5, color: Color(0x8CF4F1F8))),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(10)),
                          child: const Text('Διαχείριση', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 11),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: Container(
                        height: 6,
                        color: Colors.white.withValues(alpha: 0.08),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: 0.75,
                          child: Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [AppColors.purpleDeep, AppColors.pink]))),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(child: _historyTile('Kápsimo', const [Color(0xFF1A1522), Color(0xFF141020)])),
                const SizedBox(width: 5),
                Expanded(child: _historyTile('Εξάρχεια', const [Color(0xFF1C1622), Color(0xFF151020)], ring: AppColors.pink)),
                const SizedBox(width: 5),
                Expanded(child: _historyTile('Anodos', const [Color(0xFF1D1730), Color(0xFF161126)])),
              ],
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ΙΔΙΩΤΙΚΟΤΗΤΑ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
            const SizedBox(height: 9),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: Colors.white.withValues(alpha: 0.035),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Column(
                children: [
                  _settingsRow('Ποιος βλέπει σε ποια πάρτι πάω', 'Μόνο οι φίλοι μου', chevron: true, onTap: _comingSoon),
                  Container(height: 1, color: AppColors.hairline),
                  _settingsRow(
                    'Εμφάνιση στον χάρτη όταν είμαι σε πάρτι',
                    'Οι φίλοι βλέπουν πού είσαι απόψε',
                    trailing: _mapSwitch(store),
                  ),
                  Container(height: 1, color: AppColors.hairline),
                  _settingsRow('Ποιος μπορεί να με καλέσει', 'Φίλοι και φίλοι φίλων', chevron: true, onTap: _comingSoon),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 9, 4, 0),
              child: Text(
                'Τα ιδιωτικά πάρτι στα οποία πας δεν φαίνονται ποτέ σε άτομα που δεν είναι καλεσμένα — ούτε στο προφίλ σου.',
                style: TextStyle(fontSize: 11, height: 1.5, color: AppColors.textAlpha(0.38)),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: GestureDetector(
          onTap: () => AuthService().signOut(),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              color: Colors.white.withValues(alpha: 0.035),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Center(
              child: Text('Αποσύνδεση', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.6))),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _publicSections(BuildContext context, MpStore store) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: widget.userId != null
                  ? FollowButton(targetUserId: widget.userId!)
                  : GestureDetector(
                      onTap: _comingSoon,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          gradient: AppColors.purpleGradient,
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: const Text('Ακολούθησε',
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: _comingSoon,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    border: Border.all(color: AppColors.hairline),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Text('Μήνυμα', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ΔΗΜΟΣΙΑ ΠΑΡΤΙ ΠΟΥ ΔΙΟΡΓΑΝΩΣΕ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
            const SizedBox(height: 9),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: Colors.white.withValues(alpha: 0.035),
                border: Border.all(color: AppColors.purple.withValues(alpha: 0.25)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Rooftop Σεπτεμβρίου', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  SizedBox(height: 2),
                  Text('Πέρσι · 140 ήρθαν · Κουκάκι', style: TextStyle(fontSize: 11.5, color: Color(0x8CF4F1F8))),
                ],
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            color: Colors.white.withValues(alpha: 0.03),
            border: Border.all(color: Colors.white.withValues(alpha: 0.13)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline, size: 16, color: AppColors.textAlpha(0.45)),
              const SizedBox(width: 9),
              Expanded(
                child: Text('Τα ιδιωτικά πάρτι της Κατερίνας και τα stories τους δεν είναι ορατά σε σένα.',
                    style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textAlpha(0.5))),
              ),
            ],
          ),
        ),
      ),
      // Was "ΚΟΙΝΟΙ ΦΙΛΟΙ", rendered from the const mpFriends list. There is
      // no friendship in the schema — only the asymmetric follow graph — so
      // this is now who they follow, and it only renders for a real profile.
      if (_theirFollowing != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: FutureBuilder<List<Profile>>(
            future: _theirFollowing,
            builder: (context, snapshot) {
              final people = snapshot.data ?? const <Profile>[];
              if (people.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ΑΚΟΛΟΥΘΕΙ · ${people.length}',
                      style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      for (final f in people.take(3))
                        Padding(
                          padding: const EdgeInsets.only(right: 9),
                          child: Column(
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                clipBehavior: Clip.antiAlias,
                                decoration: const BoxDecoration(shape: BoxShape.circle),
                                child: DiagonalStripePlaceholder(colors: f.placeholderColors),
                              ),
                              const SizedBox(height: 5),
                              Text(f.username,
                                  style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.55))),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
    ];
  }

  Widget _segment(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: active ? Colors.white.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(label, style: AppTextStyles.mono(size: 10.5, color: active ? AppColors.text : AppColors.textAlpha(0.45))),
      ),
    );
  }

  Widget _countPair(String value, String label) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(value, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.5))),
      ],
    );
  }

  Widget _statTile(String value, String label, {bool pink = false}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pink ? AppColors.pink.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: pink ? AppColors.pink.withValues(alpha: 0.3) : AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3, color: pink ? AppColors.pinkLight : AppColors.text)),
          const SizedBox(height: 1),
          Text(label, style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.5))),
        ],
      ),
    );
  }

  Widget _historyTile(String label, List<Color> colors, {Color? ring}) {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          border: ring != null ? Border.all(color: ring.withValues(alpha: 0.5), width: 1.5) : null,
        ),
        child: Stack(
          children: [
            DiagonalStripePlaceholder(colors: colors),
            Positioned(
              bottom: 5,
              left: 6,
              child: Text(label, style: AppTextStyles.mono(size: 8, color: AppColors.textAlpha(0.4))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingsRow(String title, String sub, {bool chevron = false, Widget? trailing, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.45))),
                ],
              ),
            ),
            if (trailing != null) trailing,
            if (chevron) Icon(Icons.chevron_right, size: 18, color: AppColors.textAlpha(0.35)),
          ],
        ),
      ),
    );
  }

  Widget _mapSwitch(MpStore store) {
    return GestureDetector(
      onTap: store.toggleMapVisible,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 42,
        height: 25,
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          gradient: store.mapVisible ? AppColors.purpleGradient : null,
          color: store.mapVisible ? null : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(99),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          alignment: store.mapVisible ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(color: store.mapVisible ? Colors.white : Colors.white.withValues(alpha: 0.6), shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}
