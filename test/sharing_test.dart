import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/controller.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/friends.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/reminders.dart';
import 'package:morsl/ui/sharing.dart';
import 'package:morsl/ui/theme.dart';

FriendConnection connection(
  String id, {
  String status = 'accepted',
  bool incoming = false,
}) => FriendConnection(
  id: id,
  accountId: '$id-account',
  name: id == 'jamie' ? 'Jamie' : 'Alex',
  email: '$id@example.test',
  status: status,
  incoming: incoming,
);

class SharingCloud extends CloudService {
  SharingCloud() : super(null, MediaStore());
  String? current = 'account';
  List<FriendConnection> connections = [
    connection('jamie'),
    connection('alex', status: 'pending', incoming: true),
  ];
  final invitationsSent = <(String, String)>[];
  final requestsSent = <String>[];
  Completer<List<FriendConnection>>? wait;
  @override
  bool get signedInWithGoogle => current != null;
  @override
  String? get account => current;
  @override
  Future<List<FriendConnection>> friends() async =>
      wait == null ? connections : await wait!.future;
  @override
  Future<void> invite(String meal, String email) async =>
      invitationsSent.add((meal, email));
  @override
  Future<void> requestFriend(String email) async {
    requestsSent.add(email);
  }

  @override
  Future<void> respondToFriend(String id, bool accept) async {
    connections = connections.where((friend) => friend.id != id).toList();
    if (accept) connections.add(connection(id));
  }
}

class NoSharingSegmentation implements SegmentationEngine {
  @override
  Future<bool> available() async => false;
  @override
  Future<String> process(String original, String output) async => original;
  @override
  String get runtime => 'test';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MorslDatabase database;
  late SharingCloud cloud;
  late MorslController app;
  late Memory memory;
  String? invited;
  setUpAll(() async {
    for (final font in ['Quicksand', 'Caveat']) {
      await (FontLoader(
        font,
      )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
    }
  });
  setUp(() {
    database = MorslDatabase(NativeDatabase.memory());
    cloud = SharingCloud();
    app = MorslController(
      repository: MemoryRepository(database),
      media: MediaStore(),
      engine: NoSharingSegmentation(),
      cloud: cloud,
      reminders: DraftReminders(),
    );
    memory = Memory(
      id: 'whole-meal',
      scope: 'account',
      createdAt: DateTime(2026, 10, 7),
      original: '',
      draft: false,
      plates: [
        Plate(id: 'first', path: '', mask: ''),
        Plate(id: 'second', path: '', mask: ''),
      ],
    );
    invited = null;
  });
  tearDown(() async {
    app.dispose();
    await database.close();
  });

  Future<void> openShare(WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: morslTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  invited = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => MealShareSheet(app: app, memory: memory),
                  ),
              child: const Text('Share meal'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Share meal'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'sharing lists only accepted friends and invites the whole meal',
    (tester) async {
      await openShare(tester);
      expect(find.text('Jamie'), findsOneWidget);
      expect(find.text('Alex'), findsNothing);
      await tester.tap(find.text('Jamie'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send invitation'));
      await tester.pumpAndSettle();
      expect(cloud.invitationsSent, [('whole-meal', 'jamie@example.test')]);
      expect(invited, 'Jamie');
      expect(memory.plates.length, 2);
    },
  );

  testWidgets('friends can be filtered by name and accounts invited by email', (
    tester,
  ) async {
    await openShare(tester);
    await tester.enterText(find.byType(TextField), 'Jam');
    await tester.pump();
    expect(find.text('Jamie'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'someone@example.test');
    await tester.pump();
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(cloud.invitationsSent.single, (
      'whole-meal',
      'someone@example.test',
    ));
  });

  testWidgets('an invalid email cannot send a meal invitation', (tester) async {
    await openShare(tester);
    await tester.enterText(find.byType(TextField), 'not-an-email');
    await tester.pump();
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(cloud.invitationsSent, isEmpty);
    expect(
      find.text('Choose a friend or enter their account email.'),
      findsOneWidget,
    );
  });

  testWidgets('incoming requests require acceptance before becoming friends', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: morslTheme(),
        home: FriendsScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Friend requests'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(find.text('Friend requests'), findsNothing);
    expect(cloud.connections.where((friend) => friend.accepted).length, 2);
    await tester.enterText(find.byType(TextField), 'new@example.test');
    await tester.tap(find.text('Send friend request'));
    await tester.pumpAndSettle();
    expect(cloud.requestsSent, ['new@example.test']);
  });

  testWidgets('switching accounts hides previously loaded friends', (
    tester,
  ) async {
    await openShare(tester);
    expect(find.text('Jamie'), findsOneWidget);
    cloud.current = 'other-account';
    await tester.runAsync(app.reload);
    await tester.pumpAndSettle();
    expect(find.text('Jamie'), findsNothing);
    expect(find.text('Send invitation'), findsNothing);
  });
}
