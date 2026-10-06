import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';
import 'google_account.dart';
import 'media.dart';
import 'plates.dart';

class CloudService {
  CloudService(
    this.client,
    this.media, {
    GoogleAccountPicker? googleAccountPicker,
  }) : _googleAccountPicker =
           googleAccountPicker ??
           (defaultTargetPlatform == TargetPlatform.android
               ? NativeGoogleAccountPicker()
               : null);
  final SupabaseClient? client;
  final MediaStore media;
  final GoogleAccountPicker? _googleAccountPicker;
  Future<void>? _signIn;
  bool get configured => client != null;
  String? get account => client?.auth.currentUser?.id;
  String? get email => client?.auth.currentUser?.email;
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
    final c = client!;
    final payload = memory.toJson();
    payload['plates'] = memory.plates
        .map((plate) => plate.toJson(local: false))
        .toList();
    // Only upload the creator's assets. Shared downloads are never re-uploaded.
    if (memory.ownsMeal) {
      await c.rpc('reserve_meal', params: {'meal': memory.id});
      for (final item in {
        'original': memory.original,
        'cutout': memory.cutout,
        'thumbnail': memory.thumbnail,
      }.entries) {
        if (item.value == null || item.value!.isEmpty) {
          continue;
        }
        final digest = await sha256.bind(File(item.value!).openRead()).first;
        final storagePath =
            '${memory.id}/${memory.assetId ?? memory.id}/${item.key}-$digest${p.extension(item.value!)}';
        await c.storage
            .from('meal-images')
            .upload(
              storagePath,
              File(item.value!),
              fileOptions: const FileOptions(upsert: true),
            );
        payload[item.key] = storagePath;
      }
    } else {
      payload.remove('original');
      payload.remove('cutout');
      payload.remove('thumbnail');
    }
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
      final dir = await media.directory(account, j['id']);
      if (j['original'] == null || j['original'] == '') {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
        j['original'] = '';
        j['cutout'] = null;
        j['thumbnail'] = null;
        j['plates'] = [];
      }
      for (final key in ['original', 'cutout', 'thumbnail']) {
        final remote = j[key] as String?;
        if (remote == null || remote.isEmpty) {
          continue;
        }
        final target = File(p.join(dir.path, p.basename(remote)));
        // Download before committing the restored record. Interrupted writes
        // remain .partial files and cannot appear as complete memories.
        if (!await target.exists()) {
          final bytes = await c.storage.from('meal-images').download(remote);
          final partial = File('${target.path}.partial');
          await partial.writeAsBytes(bytes, flush: true);
          await partial.rename(target.path);
        }
        j[key] = target.path;
      }
      j['scope'] = account;
      final restored = Memory.fromJson(j);
      restored.plates = await Future.wait(
        restored.plates.map(
          (plate) => renderPlate(restored.original, dir.path, plate),
        ),
      );
      restored.job = restored.plates.isNotEmpty || restored.cutout != null
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

  Future<void> leave(String meal) async {
    requireGoogleAccount();
    await client!.rpc('leave_meal', params: {'meal': meal});
  }

  Future<void> deleteMeal(String meal) async {
    requireGoogleAccount();
    await client!.rpc('delete_meal', params: {'meal': meal});
  }

  Future<void> removeAsset(Memory memory) async {
    requireGoogleAccount();
    final paths = await client!
        .from('meal_assets')
        .select('original,cutout,thumbnail')
        .eq('meal_id', memory.id)
        .single();
    // Remove every generated version, not just the current cutout reference.
    final prefix = paths['original'].split('/').take(2).join('/');
    final versions = await client!.storage
        .from('meal-images')
        .list(path: prefix);
    final files = versions.map((object) => '$prefix/${object.name}').toList();
    if (files.isNotEmpty) {
      await client!.storage.from('meal-images').remove(files);
    }
    await client!.rpc('remove_my_asset', params: {'meal': memory.id});
  }

  Future<List<Map<String, dynamic>>> venues(double lat, double lng) async {
    requireGoogleAccount();
    final response = await client!.functions.invoke(
      'nearby-venues',
      body: {'latitude': lat, 'longitude': lng},
    );
    return List<Map<String, dynamic>>.from(response.data['places'] ?? []);
  }
}
