import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/google_account.dart';
import 'package:morsl/services/media.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TestPicker implements GoogleAccountPicker {
  String? token = 'google-identity-token';
  int calls = 0;
  bool signedOut = false;
  Completer<void>? wait;

  @override
  Future<String?> pickAccount() async {
    calls++;
    if (wait != null) await wait!.future;
    return token;
  }

  @override
  Future<void> signOut() async => signedOut = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late CloudService cloud;
  late TestPicker picker;
  late List<http.Request> requests;
  int responseStatus = 200;
  Map<String, dynamic> profile = {};

  setUp(() {
    responseStatus = 200;
    profile = {};
    requests = [];
    picker = TestPicker();
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-publishable-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/logout')) return http.Response('', 204);
        if (responseStatus != 200) {
          return http.Response(
            jsonEncode({
              'msg': 'private-provider-error',
              'code': 'server_error',
            }),
            responseStatus,
          );
        }
        return http.Response(
          jsonEncode({
            'access_token': 'test-access-token',
            'refresh_token': 'test-refresh-token',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': 'google-account',
              'aud': 'authenticated',
              'email': 'meal@example.com',
              'created_at': '2026-10-06T00:00:00Z',
              'app_metadata': {
                'provider': 'google',
                'providers': ['google'],
              },
              'user_metadata': profile,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    cloud = CloudService(client, MediaStore(), googleAccountPicker: picker);
  });

  tearDown(() async => client.dispose());

  test('native identity token creates the Supabase Google session', () async {
    final signedIn = client.auth.onAuthStateChange.firstWhere(
      (event) => event.event == AuthChangeEvent.signedIn,
    );
    await cloud.signInWithGoogle();
    final request = requests.single;
    expect(request.url.path, '/auth/v1/token');
    expect(request.url.queryParameters['grant_type'], 'id_token');
    final body = jsonDecode(request.body) as Map;
    expect(body['provider'], 'google');
    expect(body['id_token'], picker.token);
    expect(cloud.signedInWithGoogle, true);
    expect(cloud.account, 'google-account');
    expect((await signedIn).session?.user.id, 'google-account');
    await cloud.signOut();
    expect(cloud.account, null);
    expect(picker.signedOut, true);
  });

  test('closing native picker makes no request and remains a guest', () async {
    picker.token = null;
    await cloud.signInWithGoogle();
    expect(requests, isEmpty);
    expect(cloud.signedInWithGoogle, false);
  });

  test(
    'Google profile photo follows the session and clears on sign-out',
    () async {
      profile = {
        'avatar_url': 'https://lh3.googleusercontent.com/profile-photo',
      };
      expect(cloud.profilePhotoUrl, isNull);
      await cloud.signInWithGoogle();
      expect(cloud.profilePhotoUrl, profile['avatar_url']);
      await cloud.signOut();
      expect(cloud.profilePhotoUrl, isNull);
    },
  );

  test('Google picture fallback ignores invalid profile photo URLs', () async {
    profile = {
      'avatar_url': 'not-a-url',
      'picture': 'https://lh3.googleusercontent.com/profile-photo',
    };
    await cloud.signInWithGoogle();
    expect(cloud.profilePhotoUrl, profile['picture']);
  });

  test('concurrent taps share one picker and token exchange', () async {
    picker.wait = Completer<void>();
    final first = cloud.signInWithGoogle();
    final second = cloud.signInWithGoogle();
    picker.wait!.complete();
    await Future.wait([first, second]);
    expect(picker.calls, 1);
    expect(requests.length, 1);
  });

  test(
    'failed exchange keeps guest access and hides provider details',
    () async {
      responseStatus = 400;
      await expectLater(
        cloud.signInWithGoogle(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'safe message',
            'Google sign-in could not be completed. Please try again.',
          ),
        ),
      );
      expect(cloud.signedInWithGoogle, false);
      responseStatus = 200;
      await cloud.signInWithGoogle();
      expect(cloud.signedInWithGoogle, true);
    },
  );
}
