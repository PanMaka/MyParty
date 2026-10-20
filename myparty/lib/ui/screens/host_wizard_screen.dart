import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../../data/party_repository.dart';
import '../../data/profile_repository.dart';
import '../../data/social_repository.dart';
import '../../models/host_party_stats.dart';
import '../../models/profile.dart';
import '../../services/geocoding_service.dart';
import '../../utils/english_date.dart';
import '../../utils/share_party.dart';
import '../theme/app_theme.dart';
import '../widgets/address_suggestions.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/map_base.dart';
import 'chat_screen.dart';
import 'location_picker_screen.dart';

/// The 4-step "host a party" wizard: details → public/private → invite → review.
///
/// With [edit] set it is the host dashboard's **Edit party** instead: the
/// details step alone, prefilled, saving through `update_party` and popping
/// `true`. Privacy is not editable (20261014113214 explains why), and the
/// invite step is not offered — adding guests to an existing party is in
/// docs/backlog.md.
class HostWizardScreen extends StatefulWidget {
  const HostWizardScreen({
    super.key,
    this.repository,
    this.social,
    this.profiles,
    this.picker,
    this.locate,
    this.share,
    this.edit,
    this.editCoverUrl,
    this.geocoder,
  });

  /// The party being edited, as the dashboard last fetched it. Null creates.
  final HostPartyStats? edit;

  /// Its current cover, already signed, so the tile shows what is there.
  final String? editCoverUrl;

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

  /// The done screen's share sheet; tests record instead of opening one.
  final ShareText? share;

  /// Address search and reverse lookups (MapTiler). Shared with the picker.
  final GeocodingService? geocoder;

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
  final _areaController = TextEditingController();
  final _descController = TextEditingController();
  final _addressFocus = FocusNode();

  late final GeocodingService _geocoder = widget.geocoder ?? GeocodingService();
  late final GeocodeSearchController _search = GeocodeSearchController(
    service: _geocoder,
    near: _searchBias,
  );

  /// Set when Continue is pressed on step 1 with no pin; cleared as soon as
  /// there is one. "Where" is the only required question on the step — a
  /// party nobody can find is not a party — and only the pin answers it. An
  /// address alone used to, and the party then landed wherever the host's
  /// phone was (Phase 42).
  bool _whereMissing = false;

  /// THE location: chosen from a suggestion, or on [LocationPickerScreen].
  /// What `lat`/`lon` are sent as, always, with no fallback.
  LatLng? _pickedPoint;

  /// Whether the address / area text came from geocoding and has not been
  /// touched since. A pin move may overwrite automatic text, never the
  /// host's own ("rooftop, 3rd floor").
  bool _addressAuto = false;
  bool _areaAuto = false;

  /// A reverse-geocoded address the host's own text kept out of the field,
  /// offered as a chip instead.
  GeocodedPlace? _addressOffer;

  /// Set when the lookup for the current pin failed, so the host knows the
  /// empty field is not a bug and can type the address themselves.
  GeocodeFailure? _reverseFailure;
  bool _reverseLoading = false;
  int _reverseGeneration = 0;

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

  bool get _editing => widget.edit != null;

  @override
  void initState() {
    super.initState();
    final edit = widget.edit;
    if (edit != null) {
      // Prefilled from the row. Address and area are their own columns since
      // Phase 42; a party created before it had the address folded into the
      // description, which therefore comes back verbatim, address and all.
      _nameController.text = edit.title;
      _addressController.text = edit.address ?? '';
      _areaController.text = edit.area ?? '';
      _descController.text = edit.description ?? '';
      _pickedPoint = LatLng(edit.lat, edit.lng);
      _selectedDate = DateTime(edit.startsAt.year, edit.startsAt.month, edit.startsAt.day);
      _selectedTime = TimeOfDay(hour: edit.startsAt.hour, minute: edit.startsAt.minute);
      _private = edit.isPrivate;
      _following = Future.value(const []);
      return;
    }
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
    if (_editing) return 'Save changes';
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
    if (_editing) return 'Guests see the change the next time they open the party';
    switch (_step) {
      case 1:
        return '4 fields, 20 seconds';
      case 2:
        return 'You can change this until it starts';
      case 3:
        return '${_invited.length} invited';
      default:
        return 'Sent to ${_people(_invited.length)} and added to their map';
    }
  }

  static String _people(int n) => n == 1 ? '1 person' : '$n people';

  Color get _accent => _private ? AppColors.pink : AppColors.purple;

  Future<void> _next() async {
    if (_editing) return _save();
    if (_step == 1 && _pickedPoint == null) {
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
      // Step 1 cannot be left without a pin, and there is no fallback: a
      // party is where the host put it or it is not created.
      final point = _pickedPoint!;
      final partyId = await _repository.createPartyWithInvites(
        party: {
          'title': _nameController.text.trim(),
          // Apart since Phase 42: address and area are columns, the
          // description is only what the host wrote there.
          'description': _descController.text.trim(),
          'address': _addressController.text.trim(),
          'area': _areaController.text.trim(),
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
          share: widget.share ?? systemShare,
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

  /// Edit mode's submit: `update_party`, then the cover if a new one was
  /// picked. A failed cover does not undo the saved details, the same split
  /// the create path makes.
  ///
  /// The end time is not on the form. If the party had one, it moves by as
  /// much as the start did, so a 4-hour party stays 4 hours long and a later
  /// start can never land after its own end (which `update_party` refuses).
  Future<void> _save() async {
    final edit = widget.edit!;
    final title = _nameController.text.trim();
    if (title.isEmpty) {
      setState(() => _submitError = 'Give the party a name.');
      return;
    }
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });

    final start = _startsAt;
    final end = edit.endsAt?.add(start.difference(edit.startsAt));
    final point = _pickedPoint ?? LatLng(edit.lat, edit.lng);
    final area = _areaController.text.trim();
    final address = _addressController.text.trim();
    final description = _descController.text.trim();

    try {
      await _repository.updateParty(PartyEdit(
        partyId: edit.partyId,
        title: title,
        description: description.isEmpty ? null : description,
        area: area.isEmpty ? null : area,
        address: address.isEmpty ? null : address,
        startsAt: start,
        endsAt: end,
        lat: point.latitude,
        lng: point.longitude,
      ));
    } catch (_) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _submitError = 'That did not save. Try again.';
        });
      }
      return;
    }

    var coverFailed = false;
    if (_cover != null) {
      try {
        await _repository.replaceCover(edit.partyId, _cover!);
      } catch (_) {
        coverFailed = true;
      }
    }
    if (!mounted) return;
    if (coverFailed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved, but the new cover didn’t upload.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    Navigator.of(context).pop(true);
  }

  /// Where address search ranks results from: the pin once there is one,
  /// else the device if location is already granted (never prompting while
  /// the host types), else central Athens — so Greece leads either way.
  Future<LatLng> _searchBias() async {
    final pin = _pickedPoint;
    if (pin != null) return pin;
    final fix = await (widget.locate ?? knownDeviceLocation)();
    return fix ?? kDefaultMapCentre;
  }

  /// A suggestion was chosen: it becomes the pin and the address at once.
  void _chooseSuggestion(GeocodedPlace place) {
    _search.clear();
    _addressFocus.unfocus();
    _reverseGeneration++; // a lookup for an older pin must not land now
    setState(() {
      _pickedPoint = place.point;
      _whereMissing = false;
      _reverseFailure = null;
      _reverseLoading = false;
      _addressOffer = null;
      _setAddress(place.label);
      _fillArea(place.area);
    });
  }

  /// The host typed in the address field: from now on it is their text.
  void _onAddressTyped(String text) {
    _addressAuto = false;
    _search.onQueryChanged(text);
    if (_addressOffer != null) setState(() => _addressOffer = null);
  }

  void _setAddress(String label) {
    _addressController.text = label;
    _addressAuto = true;
  }

  /// Pre-fills the area only where the host has not written their own.
  void _fillArea(String? area) {
    if (area == null) return;
    if (_areaController.text.trim().isEmpty || _areaAuto) {
      _areaController.text = area;
      _areaAuto = true;
    }
  }

  Future<void> _pickPoint() async {
    _search.clear();
    final spot = await Navigator.of(context).push<PickedSpot>(MaterialPageRoute(
      builder: (_) => LocationPickerScreen(
        initial: _pickedPoint,
        locate: widget.locate,
        geocoder: _geocoder,
      ),
    ));
    // Backing out of the picker keeps whatever was there before.
    if (spot == null || !mounted) return;
    final moved = spot.point != _pickedPoint;
    setState(() {
      _pickedPoint = spot.point;
      _whereMissing = false;
    });
    if (!moved) return;
    final place = spot.place;
    if (place != null) {
      // Chosen from the picker's search and not moved since: that is the
      // address, no second request needed.
      _reverseGeneration++;
      setState(() {
        _reverseFailure = null;
        _reverseLoading = false;
        _applyReverse(place);
      });
    } else {
      await _reverseGeocode(spot.point);
    }
  }

  /// The address at the pin, after the host placed or moved it by hand.
  Future<void> _reverseGeocode(LatLng point) async {
    final generation = ++_reverseGeneration;
    setState(() {
      _reverseLoading = true;
      _reverseFailure = null;
      _addressOffer = null;
    });
    final result = await _geocoder.reverse(point);
    if (!mounted || generation != _reverseGeneration) return;
    setState(() {
      _reverseLoading = false;
      switch (result) {
        case GeocodeFound(:final places) when places.isNotEmpty:
          _applyReverse(places.first);
        case GeocodeFound():
          break; // nowhere with a name: the field stays for the host to fill
        case GeocodeFailed(:final failure):
          _reverseFailure = failure;
      }
    });
  }

  /// Fills the address only if it is empty or was itself filled in
  /// automatically. The host's own words are never overwritten; the lookup
  /// is offered beside them instead.
  void _applyReverse(GeocodedPlace place) {
    if (_addressController.text.trim().isEmpty || _addressAuto) {
      _setAddress(place.label);
      _addressOffer = null;
    } else if (place.label != _addressController.text.trim()) {
      _addressOffer = place;
    }
    _fillArea(place.area);
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

  void _back() {
    if (_submitting) return;
    if (_step <= 1) {
      Navigator.of(context).pop();
    } else {
      setState(() => _step -= 1);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _areaController.dispose();
    _descController.dispose();
    _addressFocus.dispose();
    _search.dispose();
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
                        Text(_editing ? 'EDIT PARTY' : 'STEP $_step OF 4',
                            style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
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
            if (!_editing)
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
    List<TextInputFormatter>? inputFormatters,
    FocusNode? focusNode,
    Key? fieldKey,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
          const SizedBox(height: 6),
          TextField(
            key: fieldKey,
            controller: controller,
            focusNode: focusNode,
            maxLines: maxLines,
            onChanged: onChanged,
            inputFormatters: inputFormatters,
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
        // An edited party may already be in the past; its own date must stay
        // pickable or the picker asserts.
        firstDate: _editing && _selectedDate.isBefore(DateTime.now())
            ? _selectedDate
            : DateTime.now().subtract(const Duration(days: 1)),
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
        _whereSection(),
        Row(
          children: [
            Expanded(child: _datePickerField()),
            const SizedBox(width: 9),
            Expanded(child: _timePickerField()),
          ],
        ),
        // `parties.area`: one line, 80 characters, enforced by a CHECK.
        // Pre-filled from the geocoded neighbourhood until the host types.
        _field(
          'AREA (OPTIONAL)',
          _areaController,
          hint: 'e.g. Psiri',
          fieldKey: const Key('wizard-area'),
          onChanged: (_) => _areaAuto = false,
          inputFormatters: [
            LengthLimitingTextInputFormatter(maxAreaLength),
            FilteringTextInputFormatter.deny(RegExp(r'[\n\r]')),
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
          child: cover == null && widget.editCoverUrl != null
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(widget.editCoverUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(9)),
                        child: const Text('Change cover', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                )
              : cover == null
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

  /// "Where": an address search whose suggestions place the pin, and the
  /// pin itself, which is the party's location. The address is a label the
  /// host can edit freely; only the pin is required.
  Widget _whereSection() {
    final offer = _addressOffer;
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // `parties.address`: one line, 200 characters, enforced by a CHECK.
          _field(
            'ADDRESS',
            _addressController,
            hint: 'Search an address or place',
            fieldKey: const Key('wizard-address'),
            focusNode: _addressFocus,
            bottomPadding: 0,
            onChanged: _onAddressTyped,
            inputFormatters: [
              LengthLimitingTextInputFormatter(maxAddressLength),
              FilteringTextInputFormatter.deny(RegExp(r'[\n\r]')),
            ],
          ),
          AddressSuggestions(controller: _search, onSelected: _chooseSuggestion),
          const GeocodeAttribution(),
          if (offer != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GestureDetector(
                key: const Key('wizard-address-offer'),
                onTap: () => setState(() {
                  _setAddress(offer.label);
                  _addressOffer = null;
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.purple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: AppColors.purple.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    'Use “${offer.label}” for the pin’s spot',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.purpleLight),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 10),
          _mapPickBox(),
        ],
      ),
    );
  }

  /// The pin: a button to place it, then a live preview of where it is with
  /// "Adjust pin". Red when Continue was pressed without one.
  Widget _mapPickBox() {
    final point = _pickedPoint;
    final borderColor = _whereMissing
        ? AppColors.destructive
        : point != null
            ? AppColors.purple
            : AppColors.hairline;

    final Widget box;
    if (point == null) {
      box = Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: borderColor),
        ),
        child: const Text('📍 Place the pin on the map', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
      );
    } else {
      box = Container(
        height: 150,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: borderColor),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // A picture of the pin, not a second picker: nothing here takes
              // a gesture, so the page still scrolls over it.
              IgnorePointer(
                child: FlutterMap(
                  key: ValueKey(point),
                  options: MapOptions(
                    initialCenter: point,
                    initialZoom: 16,
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                  ),
                  children: [mpTileLayer()],
                ),
              ),
              const IgnorePointer(child: Center(child: PartyPinMarker(size: 34))),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(11, 7, 11, 7),
                  color: Colors.black.withValues(alpha: 0.6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(formatPickedPoint(point), style: AppTextStyles.mono(size: 11, color: AppColors.textAlpha(0.7))),
                      ),
                      const Text('Adjust pin', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.purpleLight)),
                    ],
                  ),
                ),
              ),
              // An existing party always has a place; clearing it would leave
              // the edit with nothing to save.
              if (!_editing)
                Positioned(
                  right: 6,
                  top: 6,
                  child: GestureDetector(
                    key: const Key('wizard-pick-clear'),
                    onTap: _clearPin,
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
      );
    }

    final String? note;
    final bool noteIsError;
    if (_whereMissing) {
      note = 'Choose an address or place the pin on the map';
      noteIsError = true;
    } else if (point == null) {
      note = 'The pin is the party’s location. Pick a suggestion above or place it yourself.';
      noteIsError = false;
    } else if (_reverseLoading) {
      note = 'Looking up the address…';
      noteIsError = false;
    } else if (_reverseFailure != null) {
      note = 'Couldn’t look up an address for this spot. You can type one above.';
      noteIsError = false;
    } else {
      note = null;
      noteIsError = false;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(key: const Key('wizard-pick-on-map'), onTap: _pickPoint, child: box),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 7, 4, 0),
            child: Text(
              note,
              key: const Key('wizard-where-note'),
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: noteIsError ? AppColors.destructive : AppColors.textAlpha(0.45),
              ),
            ),
          ),
      ],
    );
  }

  /// Removes the pin, and with it any address or area that came from it.
  /// The host's own text stays.
  void _clearPin() {
    _reverseGeneration++;
    setState(() {
      _pickedPoint = null;
      _reverseLoading = false;
      _reverseFailure = null;
      _addressOffer = null;
      if (_addressAuto) {
        _addressController.clear();
        _addressAuto = false;
      }
      if (_areaAuto) {
        _areaController.clear();
        _areaAuto = false;
      }
    });
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
        // Explains the link rather than offering one: the real link is the
        // party's id, which does not exist until create_party_with_invites
        // returns, so the Share button lives on the done screen. This card
        // used to copy a hardcoded `myparty.gr/p/taratsa-thanasi` and promise
        // that opening it joined the guest list — an invite-link capability
        // the app never had and, by decision, does not have: a link only
        // OPENS a party, for people already allowed to see it.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: AppColors.purple.withValues(alpha: 0.4)),
            gradient: LinearGradient(colors: [AppColors.purpleDeep.withValues(alpha: 0.22), AppColors.pink.withValues(alpha: 0.14)]),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Party link', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 5),
              Text(
                _private
                    ? 'You’ll get a link to share once the party is created. Only people you invite can open it.'
                    : 'You’ll get a link to share once the party is created. Anyone can open it.',
                style: TextStyle(fontSize: 11, height: 1.45, color: AppColors.textAlpha(0.5)),
              ),
            ],
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
  final ShareText share;
  final bool coverFailed;
  final int invitedCount;
  final String partyId;
  final String partyTitle;
  final bool isPrivate;

  const _HostDoneScreen({
    required this.share,
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
                // The real link, now that the party has an id. Both kinds get
                // one: a public party's opens for anyone, a private party's
                // only for the people invited to it (get_party under RLS).
                Padding(
                  padding: const EdgeInsets.only(top: 22),
                  child: GestureDetector(
                    key: const Key('host-done-share'),
                    onTap: () => share(partyShareText(partyId: partyId, title: partyTitle, isPrivate: isPrivate)),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: AppColors.purple.withValues(alpha: 0.5)),
                        color: AppColors.purple.withValues(alpha: 0.12),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.ios_share, size: 17),
                          SizedBox(width: 8),
                          Text('Share link', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
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
