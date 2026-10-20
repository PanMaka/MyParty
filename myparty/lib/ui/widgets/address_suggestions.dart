import 'package:flutter/material.dart';

import '../../services/geocoding_service.dart';
import '../theme/app_theme.dart';

/// What an address field shows under itself while the host types: a spinner,
/// up to five places, "no matches", or why search failed. Every message
/// that is not a list of places ends with the way out — placing the pin by
/// hand — because search is a shortcut to the pin, never the only door.
///
/// Shared by the host wizard and [LocationPickerScreen], so the two fields
/// behave as one.
class AddressSuggestions extends StatelessWidget {
  const AddressSuggestions({super.key, required this.controller, required this.onSelected});

  final GeocodeSearchController controller;
  final ValueChanged<GeocodedPlace> onSelected;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GeocodeSearchState>(
      valueListenable: controller,
      builder: (context, state, _) => switch (state) {
        GeocodeSearchIdle() => const SizedBox.shrink(),
        GeocodeSearchLoading() => _box(
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.purple),
                ),
              ),
            ),
          ),
        GeocodeSearchResults(:final places) when places.isEmpty => _box(_message(geocodeNoResultsMessage)),
        GeocodeSearchResults(:final places) => _box(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < places.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: AppColors.hairline),
                  _tile(i, places[i]),
                ],
              ],
            ),
          ),
        GeocodeSearchError(:final failure) => _box(_message(geocodeFailureMessage(failure), error: true)),
      },
    );
  }

  Widget _box(Widget child) => Container(
        key: const Key('address-suggestions'),
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: AppColors.hairline),
        ),
        child: child,
      );

  Widget _message(String text, {bool error = false}) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.35,
            color: error ? AppColors.destructive : AppColors.textAlpha(0.6),
          ),
        ),
      );

  /// "Αισχύλου 12" on top, "105 54 Αθήνα" under it: the part the host typed
  /// toward, then the part that tells two same-named streets apart.
  Widget _tile(int index, GeocodedPlace place) {
    final comma = place.label.indexOf(', ');
    final head = comma < 0 ? place.label : place.label.substring(0, comma);
    final tail = comma < 0 ? null : place.label.substring(comma + 2);
    return InkWell(
      key: Key('address-suggestion-$index'),
      onTap: () => onSelected(place),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.place_outlined, size: 18, color: AppColors.textAlpha(0.5)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(head, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  if (tail != null)
                    Text(tail, style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.5))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The attribution line, always under an address search field.
class GeocodeAttribution extends StatelessWidget {
  const GeocodeAttribution({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        child: Text(
          geocodeAttribution,
          style: TextStyle(fontSize: 10.5, height: 1.3, color: AppColors.textAlpha(0.4)),
        ),
      );
}
