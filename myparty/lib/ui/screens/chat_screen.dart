import 'package:flutter/material.dart';

import '../../models/mp_chat_message.dart';
import '../../models/mp_party.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/privacy_badge.dart';

/// Full-screen group chat for a party, seeded with mock messages.
class ChatScreen extends StatefulWidget {
  final String partyId;

  const ChatScreen({super.key, required this.partyId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  late final List<MpChatMessage> _messages = List.of(mpSeedTaratsaChat);

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(MpChatMessage(text: text, fromMe: true));
      _controller.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final party = mpParties[widget.partyId]!;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _header(context, party),
            Expanded(
              child: ListView.separated(
                controller: _scrollController,
                padding: const EdgeInsets.all(14),
                itemCount: _messages.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return Center(
                      child: Text('ΣΗΜΕΡΑ',
                          style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.3))),
                    );
                  }
                  return _bubble(_messages[i - 1]);
                },
              ),
            ),
            _inputBar(),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, MpParty party) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            (party.isPrivate ? AppColors.pink : AppColors.purple).withValues(alpha: 0.12),
            Colors.transparent,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.chevron_left, size: 26),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
              Container(
                width: 40,
                height: 40,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: party.isPrivate ? AppColors.pink : AppColors.purple, width: 1.5),
                ),
                child: const DiagonalStripePlaceholder(colors: [Color(0xFF1C1622), Color(0xFF151020)]),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(party.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 6),
                        PrivacyBadge(type: party.type),
                      ],
                    ),
                    Text(
                      party.isPrivate ? '${party.pop} μέλη · μόνο καλεσμένοι' : '${party.pop} μέλη',
                      style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.5)),
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  foregroundColor: AppColors.text,
                ),
                child: const Text('Πάρτι', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.045), borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Text(party.time.toUpperCase(), style: AppTextStyles.mono(size: 10, color: AppColors.pinkLight)),
                const SizedBox(width: 7),
                Container(width: 1, height: 11, color: Colors.white.withValues(alpha: 0.15)),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(party.sub,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.6))),
                ),
                Text('Οδηγίες', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.purpleLight)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(MpChatMessage msg) {
    if (msg.system) {
      return Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.pink.withValues(alpha: 0.14),
            border: Border.all(color: AppColors.pink.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(msg.text, style: TextStyle(fontSize: 11, color: AppColors.pinkLight)),
        ),
      );
    }

    if (msg.fromMe) {
      return Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              constraints: const BoxConstraints(maxWidth: 280),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              decoration: const BoxDecoration(
                gradient: AppColors.purpleGradient,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Text(msg.text, style: const TextStyle(fontSize: 13, height: 1.45)),
            ),
          ],
        ),
      );
    }

    final colors = msg.colors ?? const [0xFF232C40, 0xFF1A2030];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [Color(colors[0]), Color(colors[1])]),
          ),
        ),
        const SizedBox(width: 9),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [msg.author, msg.authorSub].where((s) => s != null && s.isNotEmpty).join(' · '),
                style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.45)),
              ),
              const SizedBox(height: 3),
              Container(
                constraints: const BoxConstraints(maxWidth: 260),
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(14),
                    topRight: Radius.circular(14),
                    bottomRight: Radius.circular(14),
                    bottomLeft: Radius.circular(4),
                  ),
                ),
                child: Text(msg.text, style: const TextStyle(fontSize: 13, height: 1.45)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _inputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08)))),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.07), shape: BoxShape.circle),
            child: Icon(Icons.add, size: 18, color: AppColors.textAlpha(0.6)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              onSubmitted: (_) => _send(),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Μήνυμα στο πάρτι…',
                hintStyle: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.42)),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(99), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _send,
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
              child: const Icon(Icons.arrow_upward, size: 16, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
