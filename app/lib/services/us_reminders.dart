import 'package:awesome_notifications/awesome_notifications.dart';

import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB ("Us"): the phone's own 08:00 reminder. The server sends
/// the card over the listen socket, but a closed app has no socket, so a
/// local daily notification opens the Us tab, which fetches the card.
class UsReminders {
  static const int _morningId = 8100;

  static Future<void> scheduleMorning({int hour = 8, int minute = 0}) async {
    try {
      final allowed = await AwesomeNotifications().isNotificationAllowed();
      if (!allowed) return;
      await AwesomeNotifications().cancel(_morningId);
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _morningId,
          channelKey: 'channel',
          title: 'Us · today',
          body: 'Your card for the day is ready. One number, with reasons, for both of you.',
          payload: {'navigate_to': '/us'},
          notificationLayout: NotificationLayout.Default,
          category: NotificationCategory.Reminder,
          wakeUpScreen: false,
        ),
        schedule: NotificationCalendar(hour: hour, minute: minute, second: 0, repeats: true, allowWhileIdle: true),
      );
    } catch (e) {
      Logger.debug('UsReminders.scheduleMorning failed: $e');
    }
  }

  static Future<void> cancelMorning() async {
    try {
      await AwesomeNotifications().cancel(_morningId);
    } catch (_) {}
  }
}
