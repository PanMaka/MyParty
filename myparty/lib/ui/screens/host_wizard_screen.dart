import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../../data/party_repository.dart';
import '../../data/profile_repository.dart';
import '../../data/social_repository.dart';
import '../../models/profile.dart';
import '../../utils/english_date.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/map_base.dart';
import 'chat_screen.dart';
import 'location_picker_screen.dart';

/// The 4-step "host a party" wizard: details → public/private → invite → review.
class HostWizardScreen extends StatefulWidget {
  const HostWizardScreen({
    super.key,
    this.repository,
    this.social,
    this.profiles,
    this.picker,
    this.locate,
  });

  /// Injectable so widget tests can fake every repository, as the map and
  /// profile screens do. Until the cover and the map picker arrived this was
  /// the one screen with neither seams nor a test.
  final PartyRepository? repository;
  final SocialRepository? social;
  final ProfileRepository? profiles;

  /// The cover's photo picker — a seam for the same reason
  /// [ProfileEditScreen.picker] is one.
  final ImagePicker? picker;

  /// Handed to [LocationPickerScreen]; geolocator never completes in tests.
  final LocationFix? locate;

  @override
  State<HostWizardScreen> createState() => _HostWizardScreenState();
}

class _HostWizardScreenState extends State<HostWizardScreen> {
  late final PartyRepository _repository = widget.repository ?? PartyRepository();
  late final SocialRepository _social = widget.social ?? SocialRepository();
  late final ProfileRepository _profiles = widget.profiles ?? ProfileRepository();
  late final ImagePicker _picker = widget.picker ?? ImagePicker();

  int _step = 1;
  bool _private = true;
  bool _copied = false;
  bool _submitting = false;
  String? _submitError;

  /// Real `profiles.id` uuids now, not mock slugs — these go straight into
  /// `create_party_with_invites`.
  final Set<String> _invited = {};

  late Future<List<Profile>> _following;

  /// Seeded with "{username}'s party" once the profile loads — see
  /// [_suggestName]. Starts empty rather than with a placeholder name, so
  /// nothing invented can be submitted as the title.
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _descController = TextEditingController();

  /// Set when Continue is pressed on step 1 with neither an address nor a
  /// picked spot; cleared as soon as the host supplies either. "Where" is the
  /// only required question on the step — a party nobody can find is not a
  /// party — and either answer satisfies it.
  bool _whereMissing = false;

  /// The spot chosen on [LocationPickerScreen]. When null the pin falls back
  /// to the host's own position at the moment of creating, which is what
  /// every party got before the picker existed.
  LatLng? _pickedPoint;

  /// The cover, held in memory and uploaded only after the party exists —
  /// its storage path is the party's own `{party_id}/` folder, and the id is
  /// minted by create_party_with_invites.
  Uint8List? _cover;

  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = const TimeOfDay(hour: 23, minute: 0);

  DateTime get _startsAt => DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );

  static const _titles = ['Details', 'Who sees it?', 'Invite people', 'Ready?'];

  @override
  void initState() {
    super.initState();
    // Kicked off once here rather than in build(): a FutureBuilder fed
    // straight from a method call re-queries on every rebuild, and this
    // screen rebuilds on each keystroke and step change.
    _following = _social.fetchFollowing();
    _suggestName();
  }

  /// Fills the name with "{username}'s party", unless the host has already
  /// typed something by the time the profile arrives — a suggestion must
  /// never overwrite their words. A failed fetch just leaves the field empty.
  Future<void> _suggestName() async {
    try {
      final profile = await _profiles.fetchProfile();
      if (!mounted || profile == null || _nameController.text.isNotEmpty) return;
      _nameController.text = "${profile.username}'s party";
    } catch (_) {}
  }

  String get _ctaLabel {
    switch (_step) {
      case 1:
        return 'Continue';
      case 2:
        return _private ? 'Private, continue' : 'Public, continue';
      case 3:
        return 'See what they’ll see';
      default:
        return 'Create the party';
    }
  }

  String get _footLabel {
    switch (_step) {
      case 1:
        return '4 fields, 20 seconds';
      case 2:
        return 'You can change this until it starts';
      case 3:
        return '${_invited.length} invited + anyone who opens the link';
      default:
        return 'Sent to ${_people(_invited.length)} and added to their map';
    }
  }

  static String _people(int n) => n == 1 ? '1 person' : '$n people';

  Color get _accent => _private ? AppColors.pink : AppColors.purple;

  Future<void> _next() async {
    if (_step == 1 && _addressController.text.trim().isEmpty && _pickedPoint == null) {
      setState(() => _whereMissing = true);
      return;
    }
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
      final point = _pickedPoint ?? await _resolveLocation();
      final partyId = await _repository.createPartyWithInvites(
        party: {
          'title': _nameController.text.trim(),
          'description': [_addressController.text.trim(), _descController.text.trim()]
              .where((part) => part.isNotEmpty)
              .join('\n\n'),
          'lat': point.latitude,
          'lon': point.longitude,
          'starts_at': _startsAt.toUtc().toIso8601String(),
          'is_private': _private,
        },
        // Anyone here that the host has a block with is dropped server-side
        // by create_party_with_invites, so the count on the done screen can
        // legitimately be higher than the invitations actually written.
        inviteeIds: _invited.toList(),
      );
      // The party exists from here on, so nothing below may fail the submit.
      // A cover that did not make it is reported on the done screen and the
      // party stays exactly as live as one created with no cover at all.
      var coverFailed = false;
      if (_cover != null) {
        try {
          await _repository.uploadCover(partyId, _cover!);
        } catch (_) {
          coverFailed = true;
        }
      }
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _HostDoneScreen(
          coverFailed: coverFailed,
          invitedCount: _invited.length,
          // The real uuid create_party_with_invites just returned. The done
          // screen's "open the chat" button used to push a hardcoded mock
          // key; the host is the party's host, so can_chat_in_party is
          // already true for them and the chat opens empty rather than
          // erroring.
          partyId: partyId,
          partyTitle: _nameController.text.trim(),
          isPrivate: _private,
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitError = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<LatLng> _resolveLocation() async {
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
    final position = await Geolocator.getCurrentPosition();
    return LatLng(position.latitude, position.longitude);
  }

  Future<void> _pickCover() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      // A cover is a card header, never shown full-screen. 1600px keeps it
      // sharp on any phone and a JPEG at 85 lands well under the bucket's 5MB.
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    // Checked now rather than discovered after the party exists: the bucket
    // takes JPEG and PNG only, and saying so at pick time lets the host choose
    // another picture instead of getting a party with a failed cover.
    if (PartyRepository.coverContentType(bytes) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That image can’t be used as a cover. Try a JPEG or PNG photo.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _cover = bytes);
  }

  Future<void> _pickPoint() async {
    final point = await Navigator.of(context).push<LatLng>(MaterialPageRoute(
      builder: (_) => LocationPickerScreen(initial: _pickedPoint, locate: widget.locate),
    ));
    // Backing out of the picker keeps whatever was there before.
    if (point == null || !mounted) return;
    setState(() {
      _pickedPoint = point;
      _whereMissing = false;
    });
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
                        Text('STEP $_step OF 4', style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
                        Text(_titles[_step - 1], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Text('Cancel', style: TextStyle(fontSize: 12, color: AppColors.textAlpha(0.45))),
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

  Widget _field(
    String label,
    TextEditingController controller, {
    bool mono = false,
    int maxLines = 1,
    String? hint,
    String? error,
    ValueChanged<String>? onChanged,
    double bottomPadding = 13,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLines: maxLines,
            onChanged: onChanged,
            style: mono
                ? AppTextStyles.mono(size: 14, weight: FontWeight.w600, color: AppColors.text)
                : const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: AppColors.textAlpha(0.3)),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              contentPadding: const EdgeInsets.all(13),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: AppColors.hairline)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: AppColors.hairline)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: AppColors.purple)),
              errorText: error,
              errorStyle: const TextStyle(fontSize: 11.5, color: AppColors.destructive),
              errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: AppColors.destructive)),
              focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: AppColors.destructive, width: 1.5)),
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
    return _pickerField('DATE', label, () async {
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
    return _pickerField('TIME', label, () async {
      final picked = await showTimePicker(context: context, initialTime: _selectedTime);
      if (picked != null) setState(() => _selectedTime = picked);
    });
  }

  Widget _step1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _coverTile(),
        _field('NAME', _nameController),
        _field(
          'ADDRESS OR VENUE',
          _addressController,
          hint: 'e.g. 12 Example Street, Athens',
          error: _whereMissing ? 'This field is necessary' : null,
          bottomPadding: 0,
          onChanged: (_) => setState(() => _whereMissing = false),
        ),
        _orDivider(),
        _mapPickBox(),
        Row(
          children: [
            Expanded(child: _datePickerField()),
            const SizedBox(width: 9),
            Expanded(child: _timePickerField()),
          ],
        ),
        _field('DESCRIPTION (OPTIONAL)', _descController, maxLines: 4, hint: 'e.g. This is going to be fun!'),
      ],
    );
  }

  Widget _coverTile() {
    final cover = _cover;
    return GestureDetector(
      key: const Key('wizard-cover'),
      onTap: _pickCover,
      child: Container(
        height: 132,
        margin: const EdgeInsets.only(bottom: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: cover == null
              ? DiagonalStripePlaceholder(
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
                      Text('cover · photo (optional)', style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.4))),
                    ],
                  ),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(cover, fit: BoxFit.cover),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(9)),
                        child: const Text('Change cover', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    Positioned(
                      right: 6,
                      top: 6,
                      child: GestureDetector(
                        key: const Key('wizard-cover-remove'),
                        onTap: () => setState(() => _cover = null),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
                          child: const Icon(Icons.close, size: 16),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// The "where" half of the review card's subtitle. Step 1 lets a picked
  /// spot stand in for the address, so the address can be empty here.
  String _reviewWhere() {
    final address = _addressController.text.trim();
    return address.isNotEmpty ? address : 'See map for location';
  }

  Widget _orDivider() {
    Widget line() => Expanded(child: Container(height: 1, color: AppColors.hairline));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          line(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text('or', style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
          ),
          line(),
        ],
      ),
    );
  }

  /// The second answer to "where": a spot on the map. Red alongside the
  /// address field when neither is given, because either one would do.
  Widget _mapPickBox() {
    final point = _pickedPoint;
    final borderColor = _whereMissing
        ? AppColors.destructive
        : point != null
            ? AppColors.purple
            : AppColors.hairline;

    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            key: const Key('wizard-pick-on-map'),
            onTap: _pickPoint,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: borderColor),
              ),
              child: point == null
                  ? const Text('📍 Pick point on map', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))
                  : Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('📍 Pinned on the map', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(formatPickedPoint(point), style: AppTextStyles.mono(size: 11, color: AppColors.textAlpha(0.5))),
                            ],
                          ),
                        ),
                        const Text('Change', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.purpleLight)),
                        const SizedBox(width: 6),
                        GestureDetector(
                          key: const Key('wizard-pick-clear'),
                          onTap: () => setState(() => _pickedPoint = null),
                          child: Icon(Icons.close, size: 18, color: AppColors.textAlpha(0.5)),
                        ),
                      ],
                    ),
            ),
          ),
          // Said out loud because nothing turns a typed address into a point
          // (no geocoder — see LocationPickerScreen): without a picked spot
          // the pin goes where the phone is, and a host writing an address
          // across town would otherwise not find out until guests did.
          if (point == null && !_whereMissing)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 7, 4, 0),
              child: Text(
                'No spot picked? The pin goes where you are when you create the party.',
                style: TextStyle(fontSize: 11.5, height: 1.4, color: AppColors.textAlpha(0.4)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _step2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _typeCard(
          selected: _private,
          icon: Icons.lock,
          title: 'Private party',
          desc: 'Shows on the map only for the people you invite. Nobody else sees the party, its address or its story.',
          accent: AppColors.pink,
          onTap: () => setState(() => _private = true),
        ),
        const SizedBox(height: 11),
        _typeCard(
          selected: !_private,
          icon: Icons.public,
          title: 'Public party',
          desc: 'Shows on the map for everyone nearby. The pin grows as interest rises.',
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
                        ? 'On the map, a private party has a dashed red pin and only your guests can see it. For anyone who isn’t invited, the party doesn’t exist.'
                        : 'On the map, a public party has a solid purple pin that grows as people gather. Everyone within 3 km can see it.',
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
                          Text('Invite link', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                          SizedBox(height: 3),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                      child: Text(_copied ? 'Copied ✓' : 'Copy', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                Text('myparty.gr/p/taratsa-thanasi', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.55))),
                const SizedBox(height: 9),
                Text('Send it to your group chat. Anyone who opens it joins the guest list and sees the party on the map.',
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
              Text('YOU FOLLOW', style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
              Text('${_invited.length} selected', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.purpleLight)),
            ],
          ),
        ),
        const SizedBox(height: 9),
        FutureBuilder<List<Profile>>(
          future: _following,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 22),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            if (snapshot.hasError) {
              return _pickerNotice('The list didn’t load. Try again.');
            }
            final people = snapshot.data ?? const <Profile>[];
            if (people.isEmpty) {
              return _pickerNotice(
                'You don’t follow anyone yet. You can still create the party and share it with the link.',
              );
            }
            return Column(children: [for (final p in people) _personRow(p)]);
          },
        ),
      ],
    );
  }

  Widget _pickerNotice(String message) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Text(message,
          style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textAlpha(0.5))),
    );
  }

  Widget _personRow(Profile f) {
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
                child: DiagonalStripePlaceholder(colors: f.placeholderColors),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.username, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                    Text('${f.followerCount} ${f.followerCount == 1 ? 'follower' : 'followers'}',
                        style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.42))),
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
        Text('This is what your ${_invited.length} ${_invited.length == 1 ? 'guest' : 'guests'} will see on their map and in their feed.',
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
                    if (_cover != null)
                      Image.memory(_cover!, fit: BoxFit.cover)
                    else
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
                        child: Text(_private ? 'PRIVATE · INVITED ONLY' : 'PUBLIC', style: AppTextStyles.mono(size: 9)),
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
                          Text('${formatPartyStartEn(_startsAt)} · ${_reviewWhere()}',
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
                    if (_descController.text.trim().isNotEmpty)
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
                              child: Text(_private ? 'Coming' : 'Interested', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
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
                        ? 'Your ${_invited.length} ${_invited.length == 1 ? 'guest sees' : 'guests see'} the address, story and chat. Nobody else sees anything.'
                        : 'Everyone near you sees it on the map. The address is public.',
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
  final bool coverFailed;
  final int invitedCount;
  final String partyId;
  final String partyTitle;
  final bool isPrivate;

  const _HostDoneScreen({
    required this.coverFailed,
    required this.invitedCount,
    required this.partyId,
    required this.partyTitle,
    required this.isPrivate,
  });

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
                const Text('Your party is live', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    isPrivate
                        ? 'Sent to ${invitedCount == 1 ? '1 person' : '$invitedCount people'} and added to their map. The group chat is open.'
                        : 'It’s on the map. Anyone nearby can see it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, height: 1.55, color: AppColors.textAlpha(0.6)),
                  ),
                ),
                if (coverFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'The cover didn’t upload, so the party is live without one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.destructive.withValues(alpha: 0.9)),
                    ),
                  ),
                // The wizard creates BOTH kinds, which makes this the entry
                // point most likely to strand someone: a public party has no
                // chat since 20260825094044, so offering to open one would
                // hand the host a screen that can never load a message and
                // whose composer the messages policy refuses.
                if (isPrivate)
                  Padding(
                    padding: const EdgeInsets.only(top: 22),
                    child: GestureDetector(
                      onTap: () {
                        Navigator.of(context).popUntil((route) => route.isFirst);
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ChatScreen(
                            partyId: partyId,
                            partyTitle: partyTitle,
                            isPrivate: isPrivate,
                          ),
                        ));
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: const Text('Open the group chat', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).popUntil((route) => route.isFirst),
                    child: Text('Done', style: TextStyle(fontSize: 12.5, color: AppColors.textAlpha(0.45))),
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
