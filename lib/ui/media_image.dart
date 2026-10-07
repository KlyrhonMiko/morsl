import 'dart:ui' as ui;
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../services/media.dart';

ImageProvider<Object> mediaImage(String path) =>
    MediaStore.isRemote(path) ? MediaImage(path) : FileImage(File(path));

/// Stable references, never expiring URLs, are the image-cache keys.
class MediaImage extends ImageProvider<MediaImage> {
  MediaImage(this.path)
    : account = MediaStore.imageStore?.accountIdentity?.call() ?? 'guest';
  final String path, account;
  @override
  Future<MediaImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(MediaImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _decode(decode), scale: 1);
  Future<ui.Codec> _decode(ImageDecoderCallback decode) async {
    try {
      final store = MediaStore.imageStore ?? MediaStore();
      if ((store.accountIdentity?.call() ?? 'guest') != account) {
        throw StateError('Account changed.');
      }
      final bytes = await store.read(path);
      if ((store.accountIdentity?.call() ?? 'guest') != account) {
        throw StateError('Account changed.');
      }
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MediaImage && other.path == path && other.account == account;
  @override
  int get hashCode => Object.hash(path, account);
}
