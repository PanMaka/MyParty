import 'package:flutter/material.dart';

/// A mock friend, used in the host wizard's invite list and profile's mutual friends.
class MpFriend {
  final String id;
  final String name;
  final String sub;
  final List<Color> colors;

  const MpFriend({
    required this.id,
    required this.name,
    required this.sub,
    required this.colors,
  });
}

const List<MpFriend> mpFriends = [
  MpFriend(
    id: 'eleni',
    name: 'Ελένη Σταμάτη',
    sub: 'σε 12 κοινά πάρτι',
    colors: [Color(0xFF232C40), Color(0xFF1A2030)],
  ),
  MpFriend(
    id: 'aris',
    name: 'Άρης Κοντός',
    sub: 'σε 8 κοινά πάρτι',
    colors: [Color(0xFF241E3C), Color(0xFF1B1630)],
  ),
  MpFriend(
    id: 'zoi',
    name: 'Ζωή Μαυρίδη',
    sub: 'σε 5 κοινά πάρτι',
    colors: [Color(0xFF2E1F28), Color(0xFF241820)],
  ),
  MpFriend(
    id: 'lefteris',
    name: 'Λευτέρης Νταής',
    sub: 'νέος φίλος',
    colors: [Color(0xFF1E2A2A), Color(0xFF161F20)],
  ),
];
