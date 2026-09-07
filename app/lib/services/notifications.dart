import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:awesome_notifications/awesome_notifications.dart';

import 'package:omi/app_globals.dart';
import 'package:omi/pages/home/page.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/logger.dart';
import 'package:url_launcher/url_launcher.dart';

// Re-export the main notification service for backward compatibility
// All notification functionality is now handled by the platform-aware service

export 'package:omi/services/notifications/notification_service.dart';

class NotificationUtil {
  static ReceivePort? receivePort;

  static Future<void> initializeNotificationsEventListeners() async {
    // Only after at least the action method is set, the notification events are delivered
    AwesomeNotifications().setListeners(onActionReceivedMethod: NotificationUtil.onActionReceivedMethod);
  }

  static Future<void> initializeIsolateReceivePort() async {
    receivePort = ReceivePort('Notification action port in main isolate');
    receivePort!.listen((serializedData) {
      final receivedAction = ReceivedAction().fromMap(serializedData);
      onActionReceivedMethodImpl(receivedAction);
    });

    // This initialization only happens on main isolate
    IsolateNameServer.registerPortWithName(receivePort!.sendPort, 'notification_action_port');
  }

  /// Use this method to detect when the user taps on a notification or action button
  @pragma("vm:entry-point")
  static Future<void> onActionReceivedMethod(ReceivedAction receivedAction) async {
    if (receivePort != null) {
      await onActionReceivedMethodImpl(receivedAction);
    } else {
      print(
        'onActionReceivedMethod was called inside a parallel dart isolate, where receivePort was never initialized.',
      );
      SendPort? sendPort = IsolateNameServer.lookupPortByName('notification_action_port');

      if (sendPort != null) {
        print('Redirecting the execution to main isolate process in listening...');
        dynamic serializedData = receivedAction.toMap();
        sendPort.send(serializedData);
      }
    }
  }

  static Future<void> onActionReceivedMethodImpl(ReceivedAction receivedAction) async {
    if (receivedAction.payload == null || receivedAction.payload!.isEmpty) {
      return;
    }
    if (receivedAction.payload!['type'] == 'command_result') {
      await _showCommandResult(receivedAction.payload!);
      return;
    }
    await _handleAppLinkOrDeepLink(receivedAction.payload!);
  }

  /// SIMONSBOOKCLUB: a tap on a command result shows the whole answer, with
  /// a way into ReadingRate when the result has a place there. Before this
  /// a tap opened the dashboard and the banner's truncated text was all
  /// there was (2026-09-07).
  static Future<void> _showCommandResult(Map<String, String?> payload) async {
    WidgetsFlutterBinding.ensureInitialized();
    final title = payload['title'] ?? 'ReadingRate';
    final body = payload['body'] ?? '';
    final deepLink = payload['deep_link'];
    final context = await waitUntilNonNull(() => globalNavigatorKey.currentContext);
    if (context == null || body.isEmpty || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F25),
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
        content: SingleChildScrollView(
          child: SelectableText(body, style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.4)),
        ),
        actions: [
          if (deepLink != null && deepLink.isNotEmpty)
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                final uri = Uri.tryParse(deepLink);
                if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              child: const Text('Open in ReadingRate', style: TextStyle(color: Color(0xFF6FC3B8))),
            ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close', style: TextStyle(color: Colors.white70))),
        ],
      ),
    );
  }

  /// Public entry for FCM background/terminated notification taps (#5126).
  static void handleNavigateTo(String route) {
    // Fire-and-forget: waits for navigator readiness before pushing (terminated cold start).
    unawaited(_handleAppLinkOrDeepLink({'navigate_to': route}));
  }

  /// Extract a chat/conversation deep-link from an FCM data map.
  /// Returns null when `navigate_to` is missing, empty, or not a String.
  static String? navigateToFromFcmData(Map<String, dynamic> data) {
    final navigateTo = data['navigate_to'];
    if (navigateTo is String && navigateTo.isNotEmpty) {
      return navigateTo;
    }
    return null;
  }

  /// Poll until [read] returns non-null, or [timeout] elapses.
  ///
  /// Used so terminated-state FCM taps (`getInitialMessage`) that resolve before
  /// `runApp` attach the navigator do not silently no-op (#5126; same class of
  /// race as app_links cold-start in `app_shell` / #4763).
  @visibleForTesting
  static Future<T?> waitUntilNonNull<T>(
    T? Function() read, {
    Duration timeout = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 16),
  }) async {
    final existing = read();
    if (existing != null) return existing;

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      final value = read();
      if (value != null) return value;
    }
    return null;
  }

  static Future<void> _handleAppLinkOrDeepLink(Map<String, dynamic> payload) async {
    WidgetsFlutterBinding.ensureInitialized();

    final navigateTo = payload['navigate_to'];
    if (navigateTo is! String || navigateTo.isEmpty) {
      Logger.debug('Navigate To is null');
      return;
    }

    final navigator = await waitUntilNonNull(() => globalNavigatorKey.currentState);
    if (navigator == null) {
      Logger.debug('Navigator unavailable; dropping navigate_to=$navigateTo');
      return;
    }

    navigator.pushReplacement(
      MaterialPageRoute(builder: (context) => HomePageWrapper(navigateToRoute: navigateTo)),
    );
  }

  /// SIMONSBOOKCLUB: outcome of a wake-word command, delivered in-band by
  /// the self-hosted backend over the listen socket (no APNs involved).
  static Future<void> showCommandResult(String title, String body, {String? deepLink}) async {
    final allowed = await AwesomeNotifications().isNotificationAllowed();
    if (!allowed) return;
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: 7000 + (DateTime.now().millisecondsSinceEpoch % 1000),
        channelKey: 'channel',
        actionType: ActionType.Default,
        // The full text when expanded; a tap opens the whole answer in-app.
        notificationLayout: NotificationLayout.BigText,
        title: title,
        body: body,
        payload: {
          'type': 'command_result',
          'title': title,
          'body': body,
          if (deepLink != null && deepLink.isNotEmpty) 'deep_link': deepLink,
        },
        wakeUpScreen: false,
      ),
    );
  }

  static Future<void> triggerFallNotification() async {
    final allowed = await AwesomeNotifications().isNotificationAllowed();
    if (!allowed) return;

    final ctx = globalNavigatorKey.currentContext;
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: 6,
        channelKey: 'channel',
        actionType: ActionType.Default,
        title: ctx?.l10n.fallNotificationTitle ?? 'Ouch',
        body: ctx?.l10n.fallNotificationBody ?? 'Did you fall?',
        wakeUpScreen: true,
      ),
    );
  }
}
