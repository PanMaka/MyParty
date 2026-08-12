import 'package:flutter/material.dart';

/// A single frame in the story viewer, ported from the design's `STORY` array.
class MpStoryItem {
  final String label;
  final String time;
  final String author;
  final List<Color> colors;

  const MpStoryItem({
    required this.label,
    required this.time,
    required this.author,
    required this.colors,
  });
}

const List<MpStoryItem> mpStory = [
  MpStoryItem(
    label: 'clip · πλήθος στην πίστα',
    time: '23:41',
    author: 'Δημήτρης',
    colors: [Color(0xFF221A2E), Color(0xFF181228)],
  ),
  MpStoryItem(
    label: 'φωτό · ταράτσα με θέα',
    time: '23:58',
    author: 'Ζωή',
    colors: [Color(0xFF2A1C2A), Color(0xFF1D1420)],
  ),
  MpStoryItem(
    label: 'clip · τραγούδι όλοι μαζί',
    time: '00:34',
    author: 'Στέφανος',
    colors: [Color(0xFF1B1D33), Color(0xFF141426)],
  ),
  MpStoryItem(
    label: 'φωτό · μπαλκόνι, 6 άτομα',
    time: '01:12',
    author: 'Ελένη',
    colors: [Color(0xFF2B2233), Color(0xFF1E1826)],
  ),
  MpStoryItem(
    label: 'clip · Ακρόπολη ξημερώματα',
    time: '02:47',
    author: 'Δημήτρης',
    colors: [Color(0xFF1E2130), Color(0xFF161824)],
  ),
];
