import 'package:flutter/material.dart';

import 'package:omi/utils/ui_guidelines.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import 'package:omi/backend/schema/schema.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';

/// Widget showing top 3 today's tasks with "Show all ->" button
class TodayTasksWidget extends StatelessWidget {
  const TodayTasksWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ActionItemsProvider>(
      builder: (context, provider, child) {
        // Get today's tasks - same logic as action_items_page.dart
        final now = DateTime.now();
        final startOfTomorrow = DateTime(now.year, now.month, now.day + 1);
        // Filter out old tasks (older than 7 days) - same as tasks page
        final sevenDaysAgo = now.subtract(const Duration(days: 7));

        // Get incomplete tasks due today (including recent overdue) - matches tasks page logic
        final todayTasks = provider.actionItems.where((item) {
          if (item.completed) return false;
          if (item.dueAt == null) return false;
          // Skip very old overdue tasks (older than 7 days)
          if (item.dueAt!.isBefore(sevenDaysAgo)) return false;
          // Same as tasks page: dueDate.isBefore(startOfTomorrow)
          return item.dueAt!.isBefore(startOfTomorrow);
        }).toList();

        // Take top 3
        final displayTasks = todayTasks.take(3).toList();

        // Hide if no today tasks
        if (displayTasks.isEmpty) {
          return const SizedBox.shrink();
        }

        return Container(
          // Was left:24/right:8 with a Transform.translate(-8,0) on the card
          // to drag it back into line. Plain 16 gutters, like everything else.
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with "Today" and "Show All" button
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 12),
                child: Row(
                  children: [
                    Text(context.l10n.today.toUpperCase(), style: AppStyles.sectionLabel),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        // Navigate to Tasks tab (index 2). Index 1 is Conversations.
                        context.read<HomeProvider>().setIndex(2);
                      },
                      // A section header is a label, not a control.
                      child: Text(
                        context.l10n.viewAll,
                        style: const TextStyle(color: Color(0x66FFFFFF), fontSize: 12.5, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
              // Tasks list
              if (displayTasks.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    context.l10n.noTasksForToday,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 14),
                  ),
                )
              else
                Container(
                  decoration: AppStyles.cardDecoration,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: displayTasks.map((task) => _TaskItem(task: task, provider: provider)).toList(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TaskItem extends StatelessWidget {
  final ActionItemWithMetadata task;
  final ActionItemsProvider provider;

  const _TaskItem({required this.task, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Checkbox
          GestureDetector(
            onTap: () async {
              HapticFeedback.lightImpact();
              await provider.updateActionItemState(task, !task.completed);
            },
            child: Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.only(top: 2, right: 12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: task.completed ? AppStyles.accent : const Color(0x38FFFFFF), width: 1.5),
                color: task.completed ? AppStyles.accent : Colors.transparent,
              ),
              child: task.completed ? const Icon(Icons.check, size: 14, color: Colors.black) : null,
            ),
          ),
          // Task text
          Expanded(
            child: Text(
              task.description,
              style: TextStyle(
                color: task.completed ? AppStyles.inkFaint : Colors.white,
                fontSize: 15,
                decoration: task.completed ? TextDecoration.lineThrough : null,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
