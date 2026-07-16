class Party {
  final String id;
  final String title;
  final String locationName;
  final String time;
  final String category;
  final int attendeeCount;
  final String imageUrl;

  const Party({
    required this.id,
    required this.title,
    required this.locationName,
    required this.time,
    required this.category,
    required this.attendeeCount,
    required this.imageUrl,
  });
}
