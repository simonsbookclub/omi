import 'package:flutter/material.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/pages/conversation_detail/page.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/ui_guidelines.dart';

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
///
/// Laid out as rows, not as a Stack with negative offsets. The offsets were
/// exact at one text size and clipped the clock to ":45" above about 1.3x
/// Dynamic Type, because a tight 38pt box cannot wrap "10:45".
class DayRail extends StatelessWidget {
  const DayRail({super.key, required this.conversations});

  final List<ServerConversation> conversations;

  /// The clock gutter. Wide enough for "10:45" with room to grow.
  static const double _timeWidth = 46;

  /// The dot column the rail line runs down.
  static const double _dotColumn = 18;

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
        final gap = _gapBetween(context, conversations[i + 1], c);
        if (gap != null) rows.add(gap);
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  /// Conversations arrive newest first, so `earlier` is the later item in the
  /// list and `later` the one above it.
  Widget? _gapBetween(BuildContext context, ServerConversation earlier, ServerConversation later) {
    // Only a finished conversation can start a gap. Falling back to its start
    // time would count its own length as silence.
    final ended = earlier.finishedAt;
    if (ended == null) return null;
    final began = later.startedAt ?? later.createdAt;
    final minutes = began.difference(ended).inMinutes;
    if (minutes < _gapMinutes) return null;
    return Padding(
      padding: const EdgeInsets.only(left: _timeWidth + _dotColumn, bottom: 16),
      child: Text(
        context.l10n.nothingCapturedBetween(_clock(ended), _clock(began)),
        // The point of this row is that absence is information, so it has to
        // be readable; it was 0x38, which is 1.79:1 on black.
        style: const TextStyle(color: AppStyles.inkLabel, fontSize: 12),
      ),
    );
  }

  Widget _entry(BuildContext context, ServerConversation c, {required bool last}) {
    final at = (c.startedAt ?? c.createdAt).toLocal();
    // The server already scopes a conversation to the couple; 'us' means both
    // of you were in it, 'us_others' means others were there too.
    final scope = c.us?.override ?? c.us?.scope;
    final isUs = scope == 'us' || scope == 'us_others';
    final title = c.structured.title.trim();
    final overview = c.structured.overview.trim();
    // A conversation with substance gets a full dot in your colour; a scrap
    // gets a small grey one. The rail should be readable without reading.
    final substantial = overview.isNotEmpty;
    final dotColor = isUs ? AppStyles.partner : (substantial ? AppStyles.accent : AppStyles.inkFaint);
    final dotSize = isUs || substantial ? 7.0 : 5.0;

    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: _timeWidth,
          child: Padding(
            padding: const EdgeInsets.only(right: 8, top: 1),
            child: Text(
              _clock(at),
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppStyles.inkMeta,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        // The dot, and the line running past it. The line stops at the last
        // dot rather than trailing below it by however tall the last entry is.
        SizedBox(
          width: _dotColumn,
          child: Stack(alignment: Alignment.topCenter, children: [
            if (!last)
              Positioned(
                top: 8.5,
                bottom: 0,
                child: Container(width: 1, color: const Color(0x17FFFFFF)),
              ),
            Padding(
              padding: EdgeInsets.only(top: 8.5 - dotSize / 2),
              child: Container(
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
            ),
          ]),
        ),
        Expanded(
          child: InkWell(
            onTap: () => _open(context, c),
            borderRadius: BorderRadius.circular(AppStyles.radiusSmall),
            // The row, not just its text: a title-only entry is about 19pt
            // tall, well under a usable tap target.
            child: Padding(
              padding: EdgeInsets.only(top: 1, bottom: last ? 8 : 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      title.isEmpty ? context.l10n.untitledConversation : title,
                      style: AppStyles.rowTitle.copyWith(
                        // An untitled conversation is still a conversation;
                        // inkFaint put it at 1.93:1.
                        color: title.isEmpty ? AppStyles.inkMeta : Colors.white,
                        height: 1.25,
                      ),
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
          ),
        ),
      ]),
    );
  }

  /// Plain push, like every other place that opens a conversation.
  ///
  /// This used to wrap the page in a fresh ConversationDetailProvider, which
  /// shadowed the wired ChangeNotifierProxyProvider2 from main.dart. The
  /// unwired copy has a null conversationProvider, so updateConversation was
  /// a no-op, selectedDate kept its DateTime.now() default, and the page's
  /// day-key check failed for any conversation not started today — a black
  /// screen that popped straight back. Exactly the case the "Yesterday"
  /// fallback exists to show.
  void _open(BuildContext context, ServerConversation c) {
    routeToPage(context, ConversationDetailPage(conversation: c));
  }

  static String _clock(DateTime at) {
    final l = at.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}
