import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/services/venue_location.dart';
import 'package:morsl/ui/location_access.dart';
import 'package:morsl/ui/theme.dart';

class TestLocationAccess extends LocationAccessService {
  LocationAccessStatus status = LocationAccessStatus.serviceOff;
  LocationAccessStatus permissionResult = LocationAccessStatus.ready;
  int permissionRequests = 0;
  final settingsOpened = <LocationAccessStatus>[];

  @override
  Future<LocationAccessStatus> check() async => status;
  @override
  Future<LocationAccessStatus> requestPermission() async {
    permissionRequests++;
    return status = permissionResult;
  }

  @override
  Future<bool> openSettings(LocationAccessStatus status) async {
    settingsOpened.add(status);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestLocationAccess service;
  bool? result;
  setUp(() {
    service = TestLocationAccess();
    result = null;
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: morslTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await ensureLocationAccess(
                context,
                service: service,
              ),
              child: const Text('Add photo'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add photo'));
    await tester.pumpAndSettle();
  }

  testWidgets('adding a photo prompts to turn on disabled device location', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Find restaurants nearby'), findsOneWidget);
    await tester.tap(find.text('Turn on location'));
    await tester.pumpAndSettle();
    expect(service.settingsOpened, [LocationAccessStatus.serviceOff]);
    expect(result, isNull);
    service.status = LocationAccessStatus.ready;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('location permission is requested before adding a photo', (
    tester,
  ) async {
    service.status = LocationAccessStatus.permissionNeeded;
    await open(tester);
    await tester.tap(find.text('Allow location'));
    await tester.pumpAndSettle();
    expect(service.permissionRequests, 1);
    expect(result, isTrue);
  });

  testWidgets(
    'returning from location settings requests missing app permission',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('Turn on location'));
      await tester.pumpAndSettle();
      service.status = LocationAccessStatus.permissionNeeded;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.permissionRequests, 1);
      expect(result, isTrue);
    },
  );

  testWidgets('permanently denied permission opens app settings', (
    tester,
  ) async {
    service.status = LocationAccessStatus.permissionBlocked;
    await open(tester);
    await tester.tap(find.text('Open app settings'));
    await tester.pumpAndSettle();
    expect(service.settingsOpened, [LocationAccessStatus.permissionBlocked]);
    expect(service.permissionRequests, 0);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('not now allows the photo flow to continue without location', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(service.settingsOpened, isEmpty);
    expect(service.permissionRequests, 0);
  });

  testWidgets('already enabled location does not prompt again', (tester) async {
    service.status = LocationAccessStatus.ready;
    await open(tester);
    expect(result, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.permissionRequests, 0);
  });
}
