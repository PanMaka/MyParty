/// A single bubble in the group chat screen.
class MpChatMessage {
  final String? author;
  final String? authorSub;
  final String text;
  final bool fromMe;
  final bool system;
  final List<int>? colors;

  const MpChatMessage({
    this.author,
    this.authorSub,
    required this.text,
    this.fromMe = false,
    this.system = false,
    this.colors,
  });
}

final List<MpChatMessage> mpSeedTaratsaChat = [
  const MpChatMessage(
    author: 'Δημήτρης',
    authorSub: 'host',
    text: 'Ο κώδικας της πόρτας είναι 4471, 5ος όροφος. Ασανσέρ δεξιά.',
    colors: [0xFF2E1F28, 0xFF241820],
  ),
  const MpChatMessage(
    author: 'Ζωή',
    text: 'παίρνω ταξί από Σύνταγμα στις 23:10, χωράει 2 ακόμα',
    colors: [0xFF232C40, 0xFF1A2030],
  ),
  const MpChatMessage(
    text: 'έρχομαι μαζί της, φέρνω και παγάκια',
    fromMe: true,
  ),
  const MpChatMessage(
    author: 'Στέφανος',
    text: 'ποιος φέρνει ηχείο; έχω ένα JBL αλλά θέλει φορτιστή',
    colors: [0xFF241E3C, 0xFF1B1630],
  ),
  const MpChatMessage(
    text: 'Η Ελένη μπήκε στο πάρτι',
    system: true,
  ),
];
