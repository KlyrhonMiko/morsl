import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class DraftReminders {
  final plugin = FlutterLocalNotificationsPlugin();
  bool ready = false;
  Future<void> initialize(void Function() openDrafts) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }
    tzdata.initializeTimeZones();
    tz.setLocalLocation(
      tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier),
    );
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notification'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (_) => openDrafts(),
    );
    ready = true;
    final launch = await plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      openDrafts();
    }
  }

  Future<bool> requestPermission() async {
    if (!ready) {
      return false;
    }
    if (Platform.isAndroid) {
      return await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    return await plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, sound: true, badge: true) ??
        false;
  }

  Future<void> schedule({
    required bool enabled,
    required bool hasDrafts,
    required int hour,
    required int minute,
  }) async {
    if (!ready) {
      return;
    }
    await plugin.cancel(id: 41);
    if (!enabled || !hasDrafts) {
      return;
    }
    final now = tz.TZDateTime.now(tz.local);
    var date = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (!date.isAfter(now)) {
      date = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day + 1,
        hour,
        minute,
      );
    }
    await plugin.zonedSchedule(
      id: 41,
      title: 'A little memory is waiting',
      body: 'Come back to your table. Finish your meal drafts in morsl.',
      scheduledDate: date,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'drafts',
          'Draft reminders',
          channelDescription: 'Your optional evening reminder',
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'drafts',
    );
  }
}
