class Story {
  final String id;
  final String label;
  final String imageUrl;
  final bool isLive;
  final int? liveViewerCount;
  final String? startsInText;

  const Story({
    required this.id,
    required this.label,
    required this.imageUrl,
    this.isLive = false,
    this.liveViewerCount,
    this.startsInText,
  });
}
