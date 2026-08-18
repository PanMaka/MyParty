/// The two `profiles` columns behind the ΙΔΙΩΤΙΚΟΤΗΤΑ card.
///
/// Nothing in this file enforces anything, and that is the point. The database
/// is the authority — `invite_policy` is a conjunct of the `invitations` INSERT
/// policy and `map_visibility` is a filter inside `get_parties_near_user`, so
/// deleting every line here would change what the app *displays* and nothing at
/// all about what it can *reach*. These types exist to draw the right control
/// and send the right string, not to make a decision.
///
/// The two tiers point in **opposite directions along the follow edge**, which
/// is the single easiest thing in this feature to get backwards:
///
///   * [MapVisibility.followers] — people who follow **me**
///   * [InvitePolicy.following]  — people **I** follow
///
/// Deliberate, not an oversight. Following is unilateral, so "anyone who
/// follows me may invite me" would be a spam vector with no consent in it,
/// while "only people I follow may see my parties" would hide me from the
/// audience that actually asked to see me.
library;

/// Who sees this user's hosted parties as pins on the map.
///
/// Note what this is *not*: it does not hide the user from search, from the
/// feed, or from a party they were invited to. `get_parties_near_user` returns
/// parties rather than people, so the only thing the tier can gate is the pin —
/// and a party-specific relationship (you host it, you hold an invitation, you
/// already RSVP'd) overrides the tier server-side, so a host cannot un-invite
/// someone by flipping a setting.
enum MapVisibility {
  public('public', 'Όλοι', 'Τα πάρτι σου φαίνονται σε όποιον κοιτάζει τον χάρτη'),
  followers('followers', 'Όσοι με ακολουθούν', 'Μόνο όσοι σε ακολουθούν βλέπουν τα πάρτι σου στον χάρτη'),
  private('private', 'Κανείς', 'Τα πάρτι σου δεν εμφανίζονται στον χάρτη — εκτός από όσους έχεις καλέσει');

  const MapVisibility(this.wire, this.label, this.explanation);

  /// The enum label as `public.map_visibility` spells it. Must match the
  /// database exactly — a typo here is a 22P02 at write time, not a silent
  /// fallback.
  final String wire;
  final String label;
  final String explanation;

  static MapVisibility fromWire(Object? value) {
    return MapVisibility.values.firstWhere(
      (v) => v.wire == value,
      // An unknown value means the database grew a tier this build does not
      // know about. Falling back to the PERMISSIVE end would silently show
      // parties the user had hidden, so an unrecognised tier reads as the most
      // restrictive one — wrong in the direction that cannot leak.
      orElse: () => MapVisibility.private,
    );
  }
}

/// Who may add this user to a guest list.
enum InvitePolicy {
  anyone('anyone', 'Οποιοσδήποτε', 'Ο καθένας μπορεί να σε καλέσει σε πάρτι'),
  following('following', 'Μόνο όσους ακολουθώ', 'Μόνο άτομα που ακολουθείς μπορούν να σε καλέσουν');

  const InvitePolicy(this.wire, this.label, this.explanation);

  final String wire;
  final String label;
  final String explanation;

  static InvitePolicy fromWire(Object? value) {
    return InvitePolicy.values.firstWhere(
      (v) => v.wire == value,
      // Same reasoning as MapVisibility.fromWire: unknown falls to the
      // restrictive end.
      orElse: () => InvitePolicy.following,
    );
  }
}

class ProfilePrivacy {
  const ProfilePrivacy({required this.mapVisibility, required this.invitePolicy});

  final MapVisibility mapVisibility;
  final InvitePolicy invitePolicy;

  factory ProfilePrivacy.fromRow(Map<String, dynamic> row) {
    return ProfilePrivacy(
      mapVisibility: MapVisibility.fromWire(row['map_visibility']),
      invitePolicy: InvitePolicy.fromWire(row['invite_policy']),
    );
  }

  ProfilePrivacy copyWith({MapVisibility? mapVisibility, InvitePolicy? invitePolicy}) {
    return ProfilePrivacy(
      mapVisibility: mapVisibility ?? this.mapVisibility,
      invitePolicy: invitePolicy ?? this.invitePolicy,
    );
  }
}
