/// The gender question, as the register form and Settings ask it.
///
/// [value] is the sign-up metadata string `handle_new_user` parses;
/// [label] is what the pickers show. [wire] is what `set_my_gender` takes:
/// the `public.gender` enum value, or null for [preferNotToSay], which the
/// server stores as no row at all (20261019193257).
enum Gender {
  male('male', 'Male'),
  female('female', 'Female'),
  nonBinary('non_binary', 'Non-binary'),
  preferNotToSay('prefer_not_to_say', 'Prefer not to say');

  const Gender(this.value, this.label);
  final String value;
  final String label;

  String? get wire => this == preferNotToSay ? null : value;

  /// A `user_genders.gender` value, or null (no row) as [preferNotToSay].
  /// Anything unrecognised also reads as not specified rather than throwing:
  /// a value this build does not know is still not one it can display.
  static Gender fromWire(String? wire) {
    for (final g in values) {
      if (g != preferNotToSay && g.value == wire) return g;
    }
    return preferNotToSay;
  }
}

/// Shown under the gender field on the register screen and in Settings. Says
/// what the host actually sees, including that the guest list can give an
/// answer away; 'Prefer not to say' is the way out of the counts.
const genderVisibilityNote =
    "Hosts see how many guests of each gender are going to their party. "
    "Choose 'Prefer not to say' if you don't want to be counted.";
