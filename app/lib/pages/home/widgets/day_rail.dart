import 'package:flutter/material.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:omi/pages/conversation_detail/page.dart';
import 'package:omi/utils/ui_guidelines.dart';
import 'package:provider/provider.dart';

/// SIMONSBOOKCLUB: the day, down a time rail.
///
/// Chronicle is a record of a day, so the home screen is ordered by when
/// things happened and says so. The previous design was a stack of preview
/// cards that could have been shuffled and read the same.
///
/// Two things the old list could not say: a conversation the two of you were
/// both in is marked in the partner's colour, and a stretch with nothing
/// captured is written down rather than left as a gap the reader has to
/// notice. In a lifelog, absence is information.
class DayRail extends StatelessWidget {
  const DayRail({super.key, required this.conversations});

  final List<ServerConversation> conversations;

  /// A stretch longer than this with nothing captured is worth saying.
  static const _gapMinutes = 90;

  @override
  Widget build(BuildContext context) {
    if (conversations.isEmpty) return const SizedBox.shrink();
    final rows = <Widget>[];
    for (var i = 0; i < conversations.length; i++) {
      final c = conversations[i];
      rows.add(_entry(context, c, last: i == conversations.length - 1));
      if (i < conversations.length - 1) {
        final gap = _gapBetween(conversations[i + 1], c);
        if (gap != null) rows.add(gap);
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Stack(children: [
        // The rail itself, behind the entries.
        Positioned(
          left: 45,
          top: 6,
          bottom: 10,
          child: Container(width: 1, color: const Color(0x17FFFFFF)),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 56),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
        ),
      ]),
    );
  }

  /// Conversations arrive newest first, so `earlier` is the later item in the
  /// list and `later` the one above it.
  Widget? _gapBetween(ServerConversation earlier, ServerConversation later) {
    final ended = earlier.finishedAt ?? earlier.startedAt ?? earlier.createdAt;
    final began = later.startedAt ?? later.createdAt;
    final minutes = began.difference(ended).inMinutes;
    if (minutes < _gapMinutes) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        'Nothing captured, ${_clock(ended)} to ${_clock(began)}',
        style: const TextStyle(color: Color(0x38FFFFFF), fontSize: 12),
      ),
    );
  }

  Widget _entry(BuildContext context, ServerConversation c, {required bool last}) {
    final at = (c.startedAt ?? c.createdAt).toLocal();
    // The server already scopes a conversation to the couple; 'us' means
    // both of you were in it, 'us_others' means others were there too.
    final scope = c.us?.override ?? c.us?.scope;
    final isUs = scope == 'us' || scope == 'us_others';
    final title = c.structured.title.trim();
    final overview = c.structured.overview.trim();
    // A conversation with substance gets a full dot in your colour; a scrap
    // gets a small grey one. The rail should be readable without reading.
    final substantial = overview.isNotEmpty;
    final dotColor = isUs ? AppStyles.partner : (substantial ? AppStyles.accent : const Color(0x38FFFFFF));
    final dotSize = isUs || substantial ? 7.0 : 5.0;

    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 16),
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: -56,
          top: 1,
          width: 38,
          child: Text(
            _clock(at),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Color(0x73FFFFFF),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Positioned(
          left: dotSize == 7.0 ? -13 : -12,
          top: dotSize == 7.0 ? 5 : 6,
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
        ),
        InkWell(
          onTap: () => _open(context, c),
          borderRadius: BorderRadius.circular(AppStyles.radiusSmall),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(
                  title.isEmpty ? 'Untitled' : title,
                  style: AppStyles.rowTitle.copyWith(color: title.isEmpty ? AppStyles.inkFaint : Colors.white, height: 1.25),
                ),
              ),
              if (isUs) ...[
                const SizedBox(width: 7),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppStyles.partner.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text('Us',
                      style: TextStyle(color: AppStyles.partner, fontSize: 10.5, fontWeight: FontWeight.w700)),
                ),
              ],
              if (c.starred) ...[
                const SizedBox(width: 6),
                const Icon(Icons.star_rounded, size: 14, color: AppStyles.attention),
              ],
            ]),
            if (overview.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(overview, maxLines: 2, style: AppStyles.rowSubtitle),
            ],
          ]),
        ),
      ]),
    );
  }

  void _open(BuildContext context, ServerConversation c) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider(
          create: (_) => ConversationDetailProvider(),
          child: ConversationDetailPage(conversation: c),
        ),
      ),
    );
  }

  static String _clock(DateTime at) {
    final l = at.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}
