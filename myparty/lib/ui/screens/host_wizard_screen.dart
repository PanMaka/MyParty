import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../../data/party_repository.dart';
import '../../models/mp_friend.dart';
import '../../utils/greek_date.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import 'chat_screen.dart';

/// The 4-step "host a party" wizard: details → public/private → invite → review.
class HostWizardScreen extends StatefulWidget {
  const HostWizardScreen({super.key});

  @override
  State<HostWizardScreen> createState() => _HostWizardScreenState();
}

class _HostWizardScreenState extends State<HostWizardScreen> {
  final _repository = PartyRepository();

  int _step = 1;
  bool _private = true;
  bool _copied = false;
  bool _submitting = false;
  String? _submitError;
  final Set<String> _invited = {'eleni', 'aris'};

  final _nameController = TextEditingController(text: 'Ταράτσα στου Θανάση');
  final _addressController = TextEditingController(text: 'Ζησιμοπούλου 8, Νέα Σμύρνη');
  final _descController = TextEditingController(
      text: 'Φέρτε ό,τι πίνετε. Έχει ηχείο, μη φέρετε άλλο. Ταράτσα, βάλτε κάτι ζεστό για μετά τις 3.');

  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = const TimeOfDay(hour: 23, minute: 0);

  DateTime get _startsAt => DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );

  static const _titles = ['Λεπτομέρειες', 'Ποιος το βλέπει;', 'Κάλεσε κόσμο', 'Έτοιμο;'];

  String get _ctaLabel {
    switch (_step) {
      case 1:
        return 'Συνέχεια';
      case 2:
        return _private ? 'Ιδιωτικό, συνέχεια' : 'Δημόσιο, συνέχεια';
      case 3:
        return 'Δες τι θα δουν';
      default:
        return 'Δημιούργησε το πάρτι';
    }
  }

  String get _footLabel {
    switch (_step) {
      case 1:
        return '4 πεδία, 20 δευτερόλεπτα';
      case 2:
        return 'Μπορείς να το αλλάξεις μέχρι να ξεκινήσει';
      case 3:
        return '${_invited.length} καλεσμένοι + όποιος ανοίξει το λινκ';
      default:
        return 'Στέλνεται σε ${_invited.length} φίλους και μπαίνει στον χάρτη τους';
    }
  }

  Color get _accent => _private ? AppColors.pink : AppColors.purple;

  Future<void> _next() async {
    if (_step < 4) {
      setState(() => _step += 1);
      return;
    }
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final position = await _resolveLocation();
      // mpFriends is still mock data (no real profile ids yet), so invites
      // stay empty until Phase where friends ship real.
      await _repository.createPartyWithInvites(
        party: {
          'title': _nameController.text.trim(),
          'description': '${_addressController.text.trim()}\n\n${_descController.text.trim()}',
          'lat': position.latitude,
          'lon': position.longitude,
          'starts_at': _startsAt.toUtc().toIso8601String(),
          'is_private': _private,
        },
      );
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => _HostDoneScreen(invitedCount: _invited.length)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitError = 'Κάτι πήγε στραβά. Δοκίμασε ξανά.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<Position> _resolveLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Location services disabled');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw Exception('Location permission denied');
    }
    return Geolocator.getCurrentPosition();
  }

  void _back() {
    if (_submitting) return;
    if (_step <= 1) {
      Navigator.of(context).pop();
    } else {
      setState(() => _step -= 1);
    }
  }

  void _copyLink() {
    Clipboard.setData(const ClipboardData(text: 'myparty.gr/p/taratsa-thanasi'));
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Row(
                children: [
                  IconButton(onPressed: _back, icon: const Icon(Icons.chevron_left, size: 26), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ΒΗΜΑ $_step ΑΠΟ 4', style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
                        Text(_titles[_step - 1], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Text('Άκυρο', style: TextStyle(fontSize: 12, color: AppColors.textAlpha(0.45))),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(
                children: [
                  for (var i = 1; i <= 4; i++)
                    Expanded(
                      child: Container(
                        margin: EdgeInsets.only(right: i < 4 ? 5 : 0),
                        height: 3,
                        decoration: BoxDecoration(
                          color: i <= _step ? _accent : Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: switch (_step) {
                  1 => _step1(),
                  2 => _step2(),
                  3 => _step3(),
                  _ => _step4(),
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.07)))),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: _submitting ? null : _next,
                      child: Opacity(
                        opacity: _submitting ? 0.6 : 1,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            gradient: AppColors.brandGradient,
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [BoxShadow(color: AppColors.purpleDeep.withValues(alpha: 0.4), blurRadius: 26, offset: const Offset(0, 8))],
                          ),
                          child: _submitting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : Text(_ctaLabel, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 9),
                  if (_submitError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(_submitError!, style: const TextStyle(fontSize: 11.5, color: Color(0xFFFF6B6B))),
                    ),
                  Text(_footLabel, style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.35))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, {bool mono = false, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLines: maxLines,
            style: mono
                ? AppTextStyles.mono(size: 14, weight: FontWeight.w600, color: AppColors.text)
                : const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              contentPadding: const EdgeInsets.all(13),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: AppColors.hairline)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: AppColors.hairline)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: AppColors.purple)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickerField(String label, String value, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Text(value, style: AppTextStyles.mono(size: 14, weight: FontWeight.w600, color: AppColors.text)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _datePickerField() {
    final label = '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}';
    return _pickerField('ΜΕΡΑ', label, () async {
      final picked = await showDatePicker(
        context: context,
        initialDate: _selectedDate,
        firstDate: DateTime.now().subtract(const Duration(days: 1)),
        lastDate: DateTime.now().add(const Duration(days: 365)),
      );
      if (picked != null) setState(() => _selectedDate = picked);
    });
  }

  Widget _timePickerField() {
    final label = _selectedTime.format(context);
    return _pickerField('ΩΡΑ', label, () async {
      final picked = await showTimePicker(context: context, initialTime: _selectedTime);
      if (picked != null) setState(() => _selectedTime = picked);
    });
  }

  Widget _step1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Έρχεται σύντομα'), behavior: SnackBarBehavior.floating),
          ),
          child: Container(
            height: 132,
            margin: const EdgeInsets.only(bottom: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18), style: BorderStyle.solid),
            ),
            child: DiagonalStripePlaceholder(
              colors: const [Color(0xFF171320), Color(0xFF12101A)],
              borderRadius: BorderRadius.circular(15),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.add, color: AppColors.purpleLight, size: 18),
                  ),
                  const SizedBox(height: 7),
                  Text('cover · φωτό ή βίντεο', style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.4))),
                ],
              ),
            ),
          ),
        ),
        _field('ΟΝΟΜΑ', _nameController),
        _field('ΔΙΕΥΘΥΝΣΗ Ή ΧΩΡΟΣ', _addressController),
        Row(
          children: [
            Expanded(child: _datePickerField()),
            const SizedBox(width: 9),
            Expanded(child: _timePickerField()),
          ],
        ),
        _field('ΠΕΡΙΓΡΑΦΗ', _descController, maxLines: 4),
      ],
    );
  }

  Widget _step2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _typeCard(
          selected: _private,
          icon: Icons.lock,
          title: 'Ιδιωτικό πάρτι',
          desc: 'Εμφανίζεται στον χάρτη μόνο σε όσους καλέσεις. Κανείς άλλος δεν βλέπει ούτε το πάρτι, ούτε τη διεύθυνση, ούτε το story του.',
          accent: AppColors.pink,
          onTap: () => setState(() => _private = true),
        ),
        const SizedBox(height: 11),
        _typeCard(
          selected: !_private,
          icon: Icons.public,
          title: 'Δημόσιο πάρτι',
          desc: 'Εμφανίζεται στον χάρτη σε όλους όσους είναι κοντά. Το pin μεγαλώνει όσο ανεβαίνει το ενδιαφέρον.',
          accent: AppColors.purple,
          onTap: () => setState(() => _private = false),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12), style: BorderStyle.solid),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: 6, height: 6, margin: const EdgeInsets.only(top: 5), decoration: const BoxDecoration(color: AppColors.purple, shape: BoxShape.circle)),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    _private
                        ? 'Στον χάρτη το ιδιωτικό πάρτι έχει διακεκομμένο ροζ pin και το βλέπουν μόνο οι καλεσμένοι σου. Αν κάποιος δεν είναι καλεσμένος, για αυτόν το πάρτι δεν υπάρχει.'
                        : 'Στον χάρτη το δημόσιο πάρτι έχει γεμάτο μοβ pin που μεγαλώνει όσο μαζεύεται κόσμος. Το βλέπουν όλοι μέσα σε 3 χλμ.',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: AppColors.textAlpha(0.55)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _typeCard({
    required bool selected,
    required IconData icon,
    required String title,
    required String desc,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? accent : Colors.white.withValues(alpha: 0.1), width: selected ? 1.5 : 1),
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [accent.withValues(alpha: 0.2), Colors.white.withValues(alpha: 0.03)],
                )
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: selected ? Colors.white : AppColors.textAlpha(0.5)),
                const SizedBox(width: 9),
                Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: selected ? AppColors.text : AppColors.textAlpha(0.8))),
                if (selected) ...[
                  const Spacer(),
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                    child: const Icon(Icons.check, size: 12, color: Colors.white),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 9),
            Text(desc, style: TextStyle(fontSize: 12.5, height: 1.5, color: selected ? AppColors.textAlpha(0.75) : AppColors.textAlpha(0.5))),
          ],
        ),
      ),
    );
  }

  Widget _step3() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _copyLink,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: AppColors.purple.withValues(alpha: 0.4)),
              gradient: LinearGradient(colors: [AppColors.purpleDeep.withValues(alpha: 0.22), AppColors.pink.withValues(alpha: 0.14)]),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Λινκ πρόσκλησης', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                          SizedBox(height: 3),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                      child: Text(_copied ? 'Έτοιμο ✓' : 'Αντιγραφή', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                Text('myparty.gr/p/taratsa-thanasi', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.55))),
                const SizedBox(height: 9),
                Text('Στείλ\' το στο group chat. Όποιος το ανοίξει μπαίνει στους καλεσμένους και βλέπει το πάρτι στον χάρτη.',
                    style: TextStyle(fontSize: 11, height: 1.45, color: AppColors.textAlpha(0.5))),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('ΦΙΛΟΙ', style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
              Text('${_invited.length} επιλεγμένοι', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.purpleLight)),
            ],
          ),
        ),
        const SizedBox(height: 9),
        for (final f in mpFriends) _friendRow(f),
      ],
    );
  }

  Widget _friendRow(MpFriend f) {
    final selected = _invited.contains(f.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: GestureDetector(
        onTap: () => setState(() => selected ? _invited.remove(f.id) : _invited.add(f.id)),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(13)),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(shape: BoxShape.circle),
                child: DiagonalStripePlaceholder(colors: f.colors),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                    Text(f.sub, style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.42))),
                  ],
                ),
              ),
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? AppColors.purple : Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: selected ? const Icon(Icons.check, size: 13, color: Colors.white) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step4() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Αυτό θα δουν οι ${_invited.length} καλεσμένοι σου στον χάρτη και στη ροή τους.',
            style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.textAlpha(0.55))),
        const SizedBox(height: 14),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: _accent.withValues(alpha: 0.5), width: 1.5)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const DiagonalStripePlaceholder(colors: [Color(0xFF1C1622), Color(0xFF151020)], label: 'cover'),
                    Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent]),
                      ),
                    ),
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(color: _accent.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(8)),
                        child: Text(_private ? 'ΙΔΙΩΤΙΚΟ · ΜΟΝΟ ΚΑΛΕΣΜΕΝΟΙ' : 'ΔΗΜΟΣΙΟ', style: AppTextStyles.mono(size: 9)),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 10,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_nameController.text, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                          Text('${formatPartyStart(_startsAt)} · ${_addressController.text}',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.65))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 13, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_descController.text, style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textAlpha(0.7))),
                    Padding(
                      padding: const EdgeInsets.only(top: 11),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(gradient: _private ? AppColors.pinkGradient : AppColors.purpleGradient, borderRadius: BorderRadius.circular(11)),
                              child: Text(_private ? 'Έρχομαι' : 'Μ’ ενδιαφέρει', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(11)),
                              child: const Text('Group chat', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                            ),
                          ),
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
          padding: const EdgeInsets.only(top: 12),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: 6, height: 6, margin: const EdgeInsets.only(top: 5), decoration: BoxDecoration(color: _accent, shape: BoxShape.circle)),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    _private
                        ? 'Οι ${_invited.length} καλεσμένοι βλέπουν διεύθυνση, story και chat. Κανείς άλλος δεν βλέπει τίποτα.'
                        : 'Όλοι κοντά σου το βλέπουν στον χάρτη. Η διεύθυνση είναι δημόσια.',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: AppColors.textAlpha(0.6)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HostDoneScreen extends StatelessWidget {
  final int invitedCount;

  const _HostDoneScreen({required this.invitedCount});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.1,
            colors: [AppColors.purpleDeep.withValues(alpha: 0.35), AppColors.bg],
            stops: const [0, 0.6],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [AppColors.purpleDeep, AppColors.pink]),
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: AppColors.pink.withValues(alpha: 0.45), blurRadius: 40, offset: const Offset(0, 12))],
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 32),
                ),
                const SizedBox(height: 20),
                const Text('Το πάρτι είναι ζωντανό', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Στάλθηκε σε $invitedCount φίλους και μπήκε στον χάρτη τους. Το group chat άνοιξε.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, height: 1.55, color: AppColors.textAlpha(0.6)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 22),
                  child: GestureDetector(
                    onTap: () {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChatScreen(partyId: 'taratsa')));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: const Text('Άνοιξε το group chat', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).popUntil((route) => route.isFirst),
                    child: Text('Τέλος', style: TextStyle(fontSize: 12.5, color: AppColors.textAlpha(0.45))),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
