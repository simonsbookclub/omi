import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import 'package:omi/backend/http/api/users.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/daily_summary.dart';
import 'package:omi/pages/conversation_capturing/page.dart';
import 'package:omi/pages/conversations/widgets/processing_capture.dart';
import 'package:omi/pages/conversations/widgets/today_tasks_widget.dart';
import 'package:omi/pages/home/widgets/daily_summary_card.dart';
import 'package:omi/pages/home/widgets/day_rail.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/providers/capture_provider.dart' as capture;
import 'package:omi/pages/memories/widgets/memory_graph_page.dart';
import 'package:omi/pages/onboarding/device_selection.dart';
import 'package:omi/pages/phone_calls/phone_calls_page.dart';
import 'package:omi/pages/settings/daily_summary_detail_page.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/ui_guidelines.dart';
import 'package:omi/widgets/shimmer_with_timeout.dart';

class HomeContentPage extends StatefulWidget {
  const HomeContentPage({super.key});

  @override
  State<HomeContentPage> createState() => HomeContentPageState();
}

class HomeContentPageState extends State<HomeContentPage> with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  List<DailySummary> _recentSummaries = [];
  bool _loadingSummaries = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSummaries());
  }

  Future<void> _loadSummaries() async {
    if (!mounted) return;
    setState(() => _loadingSummaries = true);
    final summaries = await getDailySummaries(limit: 3, offset: 0);
    if (mounted) {
      setState(() {
        _recentSummaries = summaries;
        _loadingSummaries = false;
      });
    }
  }

  void scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(0.0, duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Consumer<ConversationProvider>(
      builder: (context, convoProvider, child) {
        // Sorted once per build and shared by the header and the rail.
        // Calling _rail() at both use sites sorted the list twice a frame.
        final rail = _rail(context, convoProvider);
        return RefreshIndicator(
          onRefresh: () async {
            HapticFeedback.mediumImpact();
            await Future.wait([convoProvider.getInitialConversations(), _loadSummaries()]);
          },
          color: AppStyles.accent,
          backgroundColor: Colors.white,
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // The day is the subject of this screen, so the day is the
              // title — and the three numbers under it are context, on one
              // line, not three tiles competing with the heading.
              SliverToBoxAdapter(child: _buildDayHeader(context, convoProvider)),

              // Live capture widget — shows when device or phone mic is recording
              const SliverToBoxAdapter(child: ConversationCaptureWidget()),

              // Today section — TodayTasksWidget has its own header
              const SliverToBoxAdapter(child: TodayTasksWidget()),

              // Daily Recaps section — hidden entirely when not loading and empty
              if (_loadingSummaries || _recentSummaries.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _buildSectionHeader(
                    context,
                    context.l10n.dailyRecaps,
                    onViewAll: () {
                      if (!convoProvider.showDailySummaries) convoProvider.toggleDailySummaries();
                      context.read<HomeProvider>().setIndex(1);
                    },
                  ),
                ),
                SliverToBoxAdapter(child: _buildDailyRecapsPreview(context)),
              ],

              // Conversations section.
              //
              // If the user has fewer than 3 non-discarded conversations,
              // we replace the recent-conversations preview with three
              // big "get started" options so the home page doesn't feel
              // empty for new users.
              if (_nonDiscardedConversationCount(convoProvider) >= 3) ...[
                SliverToBoxAdapter(
                  child: _buildSectionHeader(
                    context,
                    rail.label,
                    onViewAll: () {
                      // Reset the daily-summaries flag so the conversations tab
                      // actually shows conversations (it persists from Daily
                      // Recaps' View All otherwise).
                      if (convoProvider.showDailySummaries) convoProvider.toggleDailySummaries();
                      context.read<HomeProvider>().setIndex(1);
                    },
                  ),
                ),
                SliverToBoxAdapter(child: DayRail(conversations: rail.items)),

                // Mind Map section — only shown for users with enough activity.
                SliverToBoxAdapter(
                  child: _buildSectionHeader(
                    context,
                    context.l10n.mindMap,
                    onViewAll: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const MemoryGraphPage(trackOpenEvent: false)),
                    ),
                    buttonLabel: context.l10n.expand,
                  ),
                ),
                SliverToBoxAdapter(child: _buildMindMapPreview(context)),

                // Clears the nav bar (100) with room to breathe. It was 160,
                // reserved for a floating chat bar deleted on 2026-09-08 —
                // sixty points of dead space at the foot of every day.
                const SliverToBoxAdapter(child: SizedBox(height: 116)),
              ] else if (convoProvider.isLoadingConversations || convoProvider.isFetchingConversations)
                // Hide both the recent-convos preview AND the get-started tiles
                // while we're still fetching — otherwise users with conversations
                // briefly see the new-user triangle UI while the network call
                // is in flight, which looks broken.
                const SliverFillRemaining(hasScrollBody: false, child: SizedBox.shrink())
              else
                // For new users (< 3 non-discarded convos): hide the conversations
                // preview AND the mind map. The 3 "get started" tiles fill the
                // remaining vertical space and sit centered between Today/Daily
                // Recaps above and the floating chat bar below.
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    // Clears the nav bar; the chat bar it used to clear is gone.
                    padding: const EdgeInsets.only(bottom: 116),
                    child: Center(child: _buildGetStartedOptions(context)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Today's conversations, newest first. The rail is a day, so it holds a
  /// day — the conversations tab is where the rest lives.
  List<ServerConversation> _todaysConversations(ConversationProvider provider) {
    final now = DateTime.now();
    return _conversationsOn(provider, now);
  }

  List<ServerConversation> _conversationsOn(ConversationProvider provider, DateTime day) {
    return provider.conversations
        .where((c) => !c.discarded)
        .where((c) {
          final at = (c.startedAt ?? c.createdAt).toLocal();
          return at.year == day.year && at.month == day.month && at.day == day.day;
        })
        .toList()
      ..sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
  }

  /// What the rail shows, and what to call it. Before the first conversation
  /// of the morning "today" is empty, and an empty rail under a heading is
  /// worse than showing the last day that had anything in it.
  ({List<ServerConversation> items, String label}) _rail(BuildContext context, ConversationProvider provider) {
    final today = _todaysConversations(provider);
    if (today.isNotEmpty) return (items: today, label: context.l10n.theDaySoFar);
    final kept = provider.conversations.where((c) => !c.discarded).toList()
      ..sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
    if (kept.isEmpty) return (items: const <ServerConversation>[], label: context.l10n.theDaySoFar);
    final last = (kept.first.startedAt ?? kept.first.createdAt).toLocal();
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday = last.year == yesterday.year && last.month == yesterday.month && last.day == yesterday.day;
    return (
      items: _conversationsOn(provider, last),
      label: isYesterday ? context.l10n.yesterday : _longDate(context, last),
    );
  }

  /// How long the day's capture spans, first to last. Not the same as how
  /// long the pendant listened, and the label says "captured" for that
  /// reason rather than claiming more than it knows.
  String? _capturedSpan(List<ServerConversation> today) {
    if (today.length < 2) return null;
    final first = (today.last.startedAt ?? today.last.createdAt);
    final last = (today.first.finishedAt ?? today.first.startedAt ?? today.first.createdAt);
    final minutes = last.difference(first).inMinutes;
    if (minutes <= 0) return null;
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  Widget _buildDayHeader(BuildContext context, ConversationProvider convoProvider) {
    final today = _todaysConversations(convoProvider);
    final span = _capturedSpan(today);
    // select, not watch. CaptureProvider notifies about once a second while
    // recording — every transcript batch, every photo chunk, a 5 s metrics
    // timer — and watch() here registered the dependency on the enclosing
    // Consumer, so the whole page (rail, recaps, mind map) rebuilt at ~1 Hz,
    // including while the user was on another tab.
    final open = context.select<ActionItemsProvider, int>((p) => p.incompleteItems.length);
    final recording =
        context.select<capture.CaptureProvider, bool>((p) => p.recordingState == RecordingState.record);
    final now = DateTime.now();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_longDate(context, now).toUpperCase(), style: AppStyles.sectionLabel),
              const SizedBox(height: 4),
              Text(context.l10n.today, style: AppStyles.screenTitle),
            ]),
          ),
          // Only what is happening now is allowed a colour up here.
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
            decoration: BoxDecoration(
              color: recording
                  ? AppStyles.live.withValues(alpha: 0.13)
                  : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(AppStyles.radiusCircular),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: recording ? AppStyles.live : AppStyles.inkFaint,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                recording ? context.l10n.listening : context.l10n.dayIdle,
                style: TextStyle(
                  color: recording ? AppStyles.live : AppStyles.inkLabel,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ]),
          ),
        ]),
        if (today.isNotEmpty || open > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 18),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 2,
              children: [
                // A plural message, not a lowercased noun: Russian needs three
                // forms after a numeral and "9 разговоры" is simply wrong.
                if (today.isNotEmpty) _statText(context.l10n.conversationCount(today.length)),
                if (span != null) ...[_dot(), _stat(span, context.l10n.capturedStat)],
                if (open > 0) ...[_dot(), _stat('$open', context.l10n.openStat)],
              ],
            ),
          )
        else
          const SizedBox(height: 18),
      ]),
    );
  }

  /// One child, not two: as two Wrap children a run could break between the
  /// number and the word it belongs to, leaving "4" ending a line and "open"
  /// starting the next.
  /// A whole phrase the translator produced, with the leading number bold.
  static final _leadingNumber = RegExp(r'^(\S+)\s+(.*)$');

  Widget _statText(String phrase) {
    final match = _leadingNumber.firstMatch(phrase);
    // A locale that puts the number last just renders plainly, rather than
    // with a stray leading space where the bold half would have been.
    if (match == null) {
      return Text(phrase, style: const TextStyle(color: Color(0x73FFFFFF), fontSize: 13));
    }
    return _stat(match.group(1)!, match.group(2)!);
  }

  Widget _stat(String value, String label) => Text.rich(
        TextSpan(children: [
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          TextSpan(text: ' $label', style: const TextStyle(color: Color(0x73FFFFFF), fontSize: 13)),
        ]),
      );

  Widget _dot() => const Text('·', style: TextStyle(color: Color(0x29FFFFFF), fontSize: 13));

  /// The app ships forty locales; hardcoded English day names on its main
  /// screen were the one thing every non-English user would see first.
  static String _longDate(BuildContext context, DateTime d) {
    return DateFormat.MMMMEEEEd(Localizations.localeOf(context).toLanguageTag()).format(d);
  }

  int _nonDiscardedConversationCount(ConversationProvider provider) {
    return provider.conversations.where((c) => !c.discarded).length;
  }

  // The capturing page only renders transcript/photos that are already
  // streaming in — it does not start the mic itself. So opening it without
  // first kicking off phone-mic recording leaves the user stuck on the
  // "waiting for transcript or photos" placeholder forever. Mirror the
  // proven start path (battery_info_widget._startRecording).
  Future<void> _startPhoneRecording(BuildContext context) async {
    // No haptic here — the option() wrapper already fires lightImpact() on tap;
    // a mediumImpact() on top of it double-vibrates on a single tap.
    final captureProvider = context.read<CaptureProvider>();
    if (captureProvider.recordingState == RecordingState.initialising) return;
    if (captureProvider.recordingState != RecordingState.record) {
      await captureProvider.streamRecording();
      PlatformManager.instance.analytics.phoneMicRecordingStarted();
    }
    // A phone-mic Transcribe Later (batch) session has no live transcript — the
    // conversations-list batch card is its surface, so skip the capturing page
    // (same as BLE batch). Surface the auto offline fallback once.
    if (captureProvider.isPhoneMicBatchRecording) {
      if (SharedPreferencesUtil().phoneBatchAuto && context.mounted) {
        AppSnackbar.showSnackbar(context.l10n.phoneMicOfflineFallbackMessage);
      }
      return;
    }
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConversationCapturingPage(topConversationId: captureProvider.topConversationId),
      ),
    );
  }

  Widget _buildGetStartedOptions(BuildContext context) {
    Widget option({required IconData icon, required String label, required VoidCallback onTap}) {
      return GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppStyles.accent, Color(0xFF2FA99C)],
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: AppStyles.accent.withValues(alpha: 0.28),
                    blurRadius: 28,
                    spreadRadius: 1,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Icon(icon, color: AppStyles.onAccent, size: 32),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: 120,
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500, height: 1.2),
              ),
            ),
          ],
        ),
      );
    }

    final phoneOption = option(
      icon: Icons.mic_rounded,
      label: 'Record with Phone',
      onTap: () => _startPhoneRecording(context),
    );
    final callOption = option(
      icon: Icons.phone_in_talk_rounded,
      label: 'Record Call',
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const PhoneCallsPage()));
      },
    );
    final deviceOption = option(
      icon: Icons.bluetooth_searching_rounded,
      label: 'Connect Device',
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const DeviceSelectionPage()));
      },
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 24),
      child: Column(
        children: [
          // Top of the triangle: Record with Phone (the simplest path).
          phoneOption,
          const SizedBox(height: 22),
          // Bottom of the triangle: the other two side by side.
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [callOption, deviceOption]),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, {VoidCallback? onViewAll, String? buttonLabel}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: onViewAll,
            child: Text(title.toUpperCase(), style: AppStyles.sectionLabel),
          ),
          const Spacer(),
          if (onViewAll != null)
            GestureDetector(
              onTap: onViewAll,
              // A section header is a label, not a card: the old pill made
              // every heading look like a control.
              child: Text(
                buttonLabel ?? context.l10n.viewAll,
                style: const TextStyle(color: Color(0x66FFFFFF), fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDailyRecapsPreview(BuildContext context) {
    const cardHeight = DailySummaryCard.height;
    if (_loadingSummaries) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: SizedBox(
          height: cardHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 16),
            itemCount: 3,
            itemBuilder: (_, __) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ShimmerWithTimeout(
                baseColor: AppStyles.backgroundSecondary,
                highlightColor: AppStyles.backgroundTertiary,
                child: Container(
                  width: DailySummaryCard.width,
                  decoration: BoxDecoration(
                    color: AppStyles.backgroundSecondary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (_recentSummaries.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      child: SizedBox(
        height: cardHeight,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(left: 16),
          itemCount: _recentSummaries.length,
          itemBuilder: (context, index) => _buildSummaryCard(context, _recentSummaries[index]),
        ),
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context, DailySummary summary) {
    return DailySummaryCard(
      summary: summary,
      dateLabel: _formatDate(context, summary.date),
      onTap: () async {
        PlatformManager.instance.analytics.dailySummaryDetailViewed(summaryId: summary.id, date: summary.date);
        // Detail page pops with ``{deleted: true, summaryId}`` when the user
        // deletes from there — drop the card so the home recap row doesn't
        // linger until the next pull-to-refresh.
        final result = await Navigator.push<dynamic>(
          context,
          MaterialPageRoute(
            builder: (context) => DailySummaryDetailPage(summaryId: summary.id, summary: summary),
          ),
        );
        if (!mounted) return;
        if (result is Map && result['deleted'] == true) {
          final deletedId = result['summaryId'] as String?;
          if (deletedId != null) {
            setState(() => _recentSummaries.removeWhere((s) => s.id == deletedId));
          }
        }
      },
    );
  }

  String _formatDate(BuildContext context, String dateStr) {
    final parts = dateStr.split('-');
    if (parts.length != 3) return dateStr;
    final year = int.tryParse(parts[0]) ?? 2024;
    final month = int.tryParse(parts[1]) ?? 1;
    final day = int.tryParse(parts[2]) ?? 1;
    final date = DateTime(year, month, day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (date == today) return context.l10n.today;
    if (date == yesterday) return context.l10n.yesterday;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${weekdays[date.weekday - 1]}, ${months[month - 1]} $day';
  }

  Widget _buildMindMapPreview(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const MemoryGraphPage(trackOpenEvent: false)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: const SizedBox(
            height: 180,
            child: IgnorePointer(
              child: MemoryGraphPage(
                embedded: true,
                showAppBar: false,
                showShareButton: false,
                trackOpenEvent: false,
                autoRebuildIfEmpty: false,
                hideRebuildButtonWhenEmpty: true,
                initialZoom: 0.6,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The filtered recent-conversation preview shown on Home for established users.
///
/// This consumes [ConversationProvider.groupedConversations], which already
/// carries the conversations page's discarded/short/starred/date filters.
