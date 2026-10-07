import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

import '../data/models.dart';
import '../data/friends.dart';
import 'google_account.dart';
import 'media.dart';

class CloudService {
  CloudService(
    this.client,
    this.media, {
    GoogleAccountPicker? googleAccountPicker,
    this._imageClient,
  }) : _googleAccountPicker =
           googleAccountPicker ??
           (defaultTargetPlatform == TargetPlatform.android
               ? NativeGoogleAccountPicker()
               : null) {
    MediaStore.imageStore = media;
    media.accountIdentity = () =>
        signedInWithGoogle ? account ?? 'guest' : 'guest';
    media.download = downloadImage;
  }
  final SupabaseClient? client;
  final MediaStore media;
  final http.Client? _imageClient;
  final GoogleAccountPicker? _googleAccountPicker;
  Future<void>? _signIn;
  bool get configured => client != null;
  String? get account => client?.auth.currentUser?.id;
  String? get email => client?.auth.currentUser?.email;
  String? get profilePhotoUrl {
    if (!signedInWithGoogle) return null;
    final metadata = client?.auth.currentUser?.userMetadata;
    for (final field in ['avatar_url', 'picture']) {
      final value = metadata?[field];
      if (value is! String) continue;
      final url = Uri.tryParse(value.trim());
      if (url != null && url.scheme == 'https' && url.host.isNotEmpty) {
        return url.toString();
      }
    }
    return null;
  }

  bool get signedInWithGoogle {
    final user = client?.auth.currentUser;
    if (user == null || user.isAnonymous) return false;
    final providers = user.appMetadata['providers'];
    return user.appMetadata['provider'] == 'google' ||
        (providers is List && providers.contains('google'));
  }

  Future<void> signInWithGoogle() async {
    if (_signIn != null) return _signIn!;
    final pending = _signInWithGoogle();
    _signIn = pending;
    try {
      await pending;
    } finally {
      _signIn = null;
    }
  }

  Future<void> _signInWithGoogle() async {
    final auth = client?.auth;
    if (auth == null) throw StateError('Google sign-in is not configured.');
    final picker = _googleAccountPicker;
    if (picker != null) {
      final token = await picker.pickAccount();
      if (token == null) {
        return; // Closing the picker leaves the guest unchanged.
      }
      try {
        await auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: token,
        );
      } on AuthException {
        throw StateError(
          'Google sign-in could not be completed. Please try again.',
        );
      }
      return;
    }
    final opened = await auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'com.morsl.app://login-callback',
      queryParams: {'prompt': 'select_account'},
    );
    if (!opened) {
      throw StateError('Could not open Google sign-in. Please retry.');
    }
  }

  Future<void> signOut() async {
    // Clear Supabase first so an SDK failure cannot leave app access enabled.
    await client?.auth.signOut();
    try {
      await _googleAccountPicker?.signOut();
    } catch (_) {
      // Google picker cleanup must not undo a successful Supabase sign-out.
    }
  }

  void requireGoogleAccount() {
    if (!signedInWithGoogle || account == null) {
      throw StateError('Sign in with Google to make changes.');
    }
  }

  Future<Map<String, dynamic>> push(Memory memory) async {
    requireGoogleAccount();
    final uploadAccount = account;
    void checkAccount() {
      requireGoogleAccount();
      if (account != uploadAccount) {
        throw StateError('Account changed during backup.');
      }
    }

    final c = client!;
    final payload = memory.toJson();
    // Only upload the creator's assets. Shared downloads are never re-uploaded.
    if (memory.ownsMeal) {
      await c.rpc('reserve_meal', params: {'meal': memory.id});
      for (final item in {
        'original': memory.original,
        'cutout': memory.cutout,
        'thumbnail': memory.thumbnail,
      }.entries) {
        checkAccount();
        if (item.value == null || item.value!.isEmpty) {
          continue;
        }
        if (MediaStore.isRemote(item.value!)) {
          payload[item.key] = MediaStore.key(item.value!);
          continue;
        }
        final bytes = await media.read(item.value!);
        final digest = sha256.convert(bytes);
        final storagePath =
            '${memory.id}/${memory.assetId ?? memory.id}/r2/${item.key}-$digest${p.extension(item.value!).toLowerCase()}';
        await uploadImage(storagePath, bytes);
        payload[item.key] = storagePath;
      }
    } else {
      payload.remove('original');
      payload.remove('cutout');
      payload.remove('thumbnail');
    }
    if (memory.ownsMeal) {
      payload['photos'] = await Future.wait(
        memory.photos.map((photo) async {
          checkAccount();
          final json = photo.toJson();
          if (MediaStore.isRemote(photo.original)) {
            json['original'] = MediaStore.key(photo.original);
          } else {
            final bytes = await media.read(photo.original);
            final key =
                '${memory.id}/${memory.assetId ?? memory.id}/r2/'
                'original-${sha256.convert(bytes)}${p.extension(photo.original).toLowerCase()}';
            await uploadImage(key, bytes);
            json['original'] = key;
          }
          return json;
        }),
      );
    } else {
      payload.remove('photos');
    }
    payload['plates'] = await Future.wait(
      memory.plates.map((plate) async {
        checkAccount();
        final json = plate.toJson(local: false);
        if (MediaStore.isRemote(plate.path) && plate.cloudPath != null) {
          return json;
        }
        final bytes = await media.read(plate.path);
        final path =
            '${memory.id}/$uploadAccount/r2/plate-${sha256.convert(bytes)}.png';
        await uploadImage(path, bytes);
        json['cloudPath'] = path;
        return json;
      }),
    );
    checkAccount();
    // Atomic RPC checks both record revisions. A repeated operation at the
    // same revisions returns its previous result rather than duplicating data.
    return Map<String, dynamic>.from(
      await c.rpc('save_memory', params: {'payload': payload}),
    );
  }

  Future<List<Memory>> pull(String account) async {
    final c = client!;
    final rows = await c.rpc('restore_memories');
    final result = <Memory>[];
    for (final raw in rows as List) {
      final j = Map<String, dynamic>.from(raw);
      if (j['original'] == null || j['original'] == '') {
        j['original'] = '';
        j['cutout'] = null;
        j['thumbnail'] = null;
        j['plates'] = [];
        j['photos'] = [];
      }
      for (final key in ['original', 'cutout', 'thumbnail']) {
        final remote = j[key] as String?;
        if (remote == null || remote.isEmpty) {
          continue;
        }
        j[key] = MediaStore.remote(remote);
        media.authorize(j[key]);
      }
      j['scope'] = account;
      final restored = Memory.fromJson(j);
      for (final photo in restored.photos) {
        photo.original = MediaStore.remote(photo.original);
        media.authorize(photo.original);
      }
      for (final plate in restored.plates) {
        if (plate.cloudPath == null) {
          throw StateError(
            'This meal uses an older image format. Start with a fresh scrapbook.',
          );
        }
        plate.path = MediaStore.remote(plate.cloudPath!);
        media.authorize(plate.path);
      }
      restored.job =
          restored.photos.any(
            (p) => p.job == JobStatus.queued || p.job == JobStatus.processing,
          )
          ? JobStatus.queued
          : restored.photos.any((p) => p.job == JobStatus.failed)
          ? JobStatus.failed
          : restored.plates.isNotEmpty || restored.cutout != null
          ? JobStatus.ready
          : JobStatus.failed;
      result.add(restored);
    }
    return result;
  }

  Future<Set<String>> authorizedIds() async =>
      (await client!.from('meals').select('id'))
          .map<String>((m) => m['id'] as String)
          .toSet();

  Future<List<Map<String, dynamic>>> invitations() async =>
      List<Map<String, dynamic>>.from(await client!.rpc('my_invitations'));
  Future<void> invite(String meal, String email) async {
    requireGoogleAccount();
    await client!.rpc(
      'invite_to_meal',
      params: {'meal': meal, 'recipient_email': email.trim()},
    );
  }

  Future<void> respond(String id, bool accept) async {
    requireGoogleAccount();
    await client!.rpc(
      'respond_to_invitation',
      params: {'invitation': id, 'accept': accept},
    );
  }

  Future<List<FriendConnection>> friends() async {
    requireGoogleAccount();
    final response = await client!.rpc('my_friends');
    return List<Map<String, dynamic>>.from(
      response,
    ).map(FriendConnection.fromJson).toList();
  }

  Future<void> requestFriend(String email) async {
    requireGoogleAccount();
    await client!.rpc(
      'request_friend',
      params: {'recipient_email': email.trim()},
    );
  }

  Future<void> respondToFriend(String id, bool accept) async {
    requireGoogleAccount();
    await client!.rpc(
      'respond_to_friend_request',
      params: {'friendship': id, 'accept': accept},
    );
  }

  Future<void> removeFriend(String id) async {
    requireGoogleAccount();
    await client!.rpc('remove_friend', params: {'friendship': id});
  }

  Future<void> leave(String meal) async {
    requireGoogleAccount();
    await client!.rpc('leave_meal', params: {'meal': meal});
  }

  Future<void> deleteMeal(String meal) async {
    requireGoogleAccount();
    await client!.rpc('delete_meal', params: {'meal': meal});
    try {
      await cleanupImages(meal: meal);
    } catch (_) {
      /* Daily sweep retries after the durable deletion. */
    }
  }

  Future<void> removeAsset(Memory memory) async {
    requireGoogleAccount();
    await client!.rpc('remove_my_asset', params: {'meal': memory.id});
    try {
      await cleanupImages(meal: memory.id);
    } catch (_) {
      /* Daily sweep retries. */
    }
  }

  Future<void> cleanupImages({String? meal}) async {
    requireGoogleAccount();
    await client!.functions.invoke(
      'image-storage',
      body: {'action': 'cleanup', 'meal': ?meal},
    );
  }

  Future<String> _imageUrl(String action, String path, {int? size}) async {
    requireGoogleAccount();
    final requestedBy = account;
    final response = await _imageRequest(action, path, size: size);
    final url = response.data['url'] as String?;
    if (requestedBy != account) throw StateError('Account changed.');
    if (url == null) throw StateError('Image storage is unavailable.');
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' || uri.path != '/functions/v1/image-storage') {
      throw StateError(
        'Image storage needs an update. Your local photo is safe.',
      );
    }
    return url;
  }

  Map<String, String> get imageHeaders {
    requireGoogleAccount();
    final token = client!.auth.currentSession?.accessToken;
    if (token == null) {
      throw StateError('Sign in again to access cloud photos.');
    }
    return {'Authorization': 'Bearer $token'};
  }

  void _checkImageResponse(http.Response response) {
    if (response.statusCode == 429) {
      throw StateError(
        'Cloud image request limit reached. Please try again later. Your local photos are safe.',
      );
    }
  }

  Future<FunctionResponse> _imageRequest(
    String action,
    String path, {
    int? size,
  }) async {
    requireGoogleAccount();
    try {
      return await client!.functions.invoke(
        'image-storage',
        body: {'action': action, 'key': path, 'size': ?size},
      );
    } on FunctionException catch (error) {
      if (error.details is Map && error.details['code'] == 'storage_full') {
        throw StateError(
          'Cloud storage is full. Your photo is saved on this device.',
        );
      }
      if (error.details is Map && error.details['code'] == 'request_limit') {
        throw StateError(
          'Cloud image request limit reached. Please try again later. Your local photos are safe.',
        );
      }
      rethrow;
    }
  }

  Future<Uint8List> downloadImage(String path) async {
    final accountBefore = account;
    final url = await _imageUrl('download', path);
    final response =
        await (_imageClient?.get(Uri.parse(url), headers: imageHeaders) ??
                http.get(Uri.parse(url), headers: imageHeaders))
            .timeout(const Duration(seconds: 60));
    _checkImageResponse(response);
    if (response.statusCode != 200) {
      throw StateError('Image could not be loaded. Connect and try again.');
    }
    if (accountBefore != account) throw StateError('Account changed.');
    return response.bodyBytes;
  }

  Future<void> uploadImage(String path, Uint8List bytes) async {
    final uploadAccount = account;
    final url = await _imageUrl('upload', path, size: bytes.length);
    final response =
        await (_imageClient?.put(
                  Uri.parse(url),
                  body: bytes,
                  headers: {
                    ...imageHeaders,
                    'Content-Type': imageContentType(path),
                  },
                ) ??
                http.put(
                  Uri.parse(url),
                  body: bytes,
                  headers: {
                    ...imageHeaders,
                    'Content-Type': imageContentType(path),
                  },
                ))
            .timeout(const Duration(seconds: 60));
    _checkImageResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Photo upload failed. Your local copy is safe; try syncing again.',
      );
    }
    if (uploadAccount != account) throw StateError('Account changed.');
    final confirmed = await _imageRequest('confirm', path, size: bytes.length);
    if (confirmed.data['ok'] != true) {
      throw StateError(
        'Photo backup could not be verified. Your local copy is safe.',
      );
    }
    if (uploadAccount != account) throw StateError('Account changed.');
  }

  static String imageContentType(String path) =>
      switch (p.extension(path).toLowerCase()) {
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.heic' => 'image/heic',
        '.heif' => 'image/heif',
        _ => 'image/jpeg',
      };

  Future<List<Map<String, dynamic>>> venues(
    double lat,
    double lng, {
    String query = '',
  }) async {
    requireGoogleAccount();
    final response = await client!.functions.invoke(
      'nearby-venues',
      body: {'latitude': lat, 'longitude': lng, 'query': query.trim()},
    );
    return List<Map<String, dynamic>>.from(response.data['places'] ?? []);
  }
}
