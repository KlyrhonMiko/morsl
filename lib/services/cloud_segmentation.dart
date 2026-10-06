import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/models.dart';
import 'plates.dart';
import 'segmentation.dart';

class CloudSegmentation
    implements
        SegmentationEngine,
        MultiSubjectSegmentationEngine,
        RemoteSegmentationEngine {
  CloudSegmentation({
    String endpoint = const String.fromEnvironment(
      'SEGMENTATION_URL',
      defaultValue: 'https://klyrhonmiko--sam3-deployment-segment.modal.run',
    ),
    http.Client Function()? clientFactory,
    String? Function()? accessToken,
    this.requestTimeout = const Duration(seconds: 120),
    this.healthTimeout = const Duration(seconds: 5),
  }) : endpoint = Uri.parse(endpoint),
       _clientFactory = clientFactory ?? http.Client.new,
       _accessToken = accessToken ?? (() => null);

  final Uri endpoint;
  final http.Client Function() _clientFactory;
  final String? Function() _accessToken;
  final Duration requestTimeout, healthTimeout;
  final Set<http.Client> _clients = {};
  bool _uploadsAllowed = false;

  @override
  bool get authenticated => _accessToken()?.isNotEmpty == true;

  @override
  bool get uploadsAllowed => _uploadsAllowed;
  @override
  set uploadsAllowed(bool value) {
    _uploadsAllowed = value;
    if (!value) {
      for (final client in _clients.toList()) {
        client.close();
      }
    }
  }

  @override
  String get runtime => 'Cloud SAM3 (Modal; contract v1)';

  bool get configured => endpoint.scheme == 'https' && endpoint.host.isNotEmpty;

  Future<Map<String, dynamic>> _request(
    http.BaseRequest request,
    Duration timeout,
  ) async {
    final token = _accessToken();
    if (token == null || token.isEmpty) {
      throw StateError('Sign in to use cloud cutouts.');
    }
    request.headers['Authorization'] = 'Bearer $token';
    final client = _clientFactory();
    _clients.add(client);
    try {
      return await (() async {
        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw StateError(switch (response.statusCode) {
            401 || 403 => 'Cloud extraction access was denied.',
            413 => 'This photo is too large for cloud extraction.',
            429 => 'Cloud extraction is busy. Please retry later.',
            _ => 'Cloud extraction is unavailable (${response.statusCode}).',
          });
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 12 * 1024 * 1024) {
            throw const FormatException('Cloud response is too large.');
          }
          bytes.add(chunk);
        }
        final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Invalid cloud response.');
        }
        return decoded;
      })().timeout(
        timeout,
        onTimeout: () {
          client.close();
          throw TimeoutException('Cloud extraction timed out. Please retry.');
        },
      );
    } on http.ClientException {
      throw StateError(
        'Could not reach cloud extraction. Check your connection.',
      );
    } finally {
      _clients.remove(client);
      client.close();
    }
  }

  @override
  Future<bool> available() async {
    if (!configured || !uploadsAllowed || !authenticated) return false;
    try {
      final result = await _request(
        http.Request(
          'GET',
          endpoint.replace(
            path: '${endpoint.path.replaceFirst(RegExp(r'/$'), '')}/health',
          ),
        ),
        healthTimeout,
      );
      return result['ready'] == true &&
          result['model'] == 'sam3' &&
          result['version'] == 1;
    } catch (_) {
      return false;
    }
  }

  void _checkUploadChoice() {
    if (!authenticated) throw StateError('Sign in to use cloud cutouts.');
    if (!uploadsAllowed) {
      throw StateError(
        'Cloud cutouts are off. Enable them to upload this photo, '
        'or edit the plate by hand.',
      );
    }
    if (!configured) {
      throw StateError('Cloud extraction URL is not configured.');
    }
  }

  @override
  Future<List<Plate>> subjects(
    String original,
    String directory, {
    Plate? region,
  }) async {
    _checkUploadChoice();
    final prepared = await compute(plateRegionBytes, <String, dynamic>{
      'original': original,
      'region': region?.toJson(),
      'limit': 1600,
    });
    _checkUploadChoice();
    if (prepared.length > 10 * 1024 * 1024) {
      throw StateError('This photo is too large for cloud extraction.');
    }
    final request = http.MultipartRequest('POST', endpoint)
      ..headers['Accept'] = 'application/json'
      ..files.add(
        http.MultipartFile.fromBytes('image', prepared, filename: 'image.png'),
      );
    final response = await _request(request, requestTimeout);
    _checkUploadChoice();
    // PNG decoding and normalization must not block Flutter's UI thread.
    final rows = await compute(_decodePlates, response);
    final plates = <Plate>[];
    for (final row in rows) {
      _checkUploadChoice();
      final bounds = row['bounds'] as List<double>;
      final plate = Plate(
        id: const Uuid().v4(),
        mask: row['mask'] as String,
        left: (region?.left ?? 0) + bounds[0] * (region?.width ?? 1),
        top: (region?.top ?? 0) + bounds[1] * (region?.height ?? 1),
        width: bounds[2] * (region?.width ?? 1),
        height: bounds[3] * (region?.height ?? 1),
        aspect: row['aspect'] as double,
      );
      plates.add(await renderPlate(original, directory, plate));
    }
    _checkUploadChoice();
    arrangePlates(plates);
    return plates;
  }

  @override
  Future<String> process(String original, String output) async {
    final plates = await subjects(original, p.dirname(output));
    if (plates.isEmpty) throw StateError('No dishes found in this photo.');
    await File(plates.first.path).copy(output);
    return output;
  }
}

List<Map<String, dynamic>> _decodePlates(Map<String, dynamic> response) {
  if (response['version'] != 1 ||
      response['model'] != 'sam3' ||
      response['maskFormat'] != 'cropped-rgba') {
    throw const FormatException('Cloud extraction uses an unsupported format.');
  }
  final rows = response['plates'];
  final size = response['imageSize'];
  if (rows is! List ||
      rows.length > 12 ||
      size is! List ||
      size.length != 2 ||
      size.any((n) => n is! int || n < 1 || n > 1600)) {
    throw const FormatException('Invalid cloud plate response.');
  }
  final plates = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (row is! Map || row['bounds'] is! List || row['mask'] is! String) {
      throw const FormatException('Invalid cloud plate.');
    }
    final rawBounds = row['bounds'] as List;
    if (rawBounds.length != 4 || rawBounds.any((n) => n is! num)) {
      throw const FormatException('Invalid plate bounds.');
    }
    final bounds = rawBounds.map((n) => (n as num).toDouble()).toList();
    if (bounds.any((n) => !n.isFinite || n < 0 || n > 1) ||
        bounds[2] <= 0 ||
        bounds[3] <= 0 ||
        bounds[0] + bounds[2] > 1.000001 ||
        bounds[1] + bounds[3] > 1.000001) {
      throw const FormatException('Invalid plate bounds.');
    }
    final encoded = row['mask'] as String;
    if (encoded.length > 4 * 1024 * 1024) {
      throw const FormatException('Plate mask is too large.');
    }
    final bytes = base64Decode(encoded);
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 24 || !listEquals(bytes.sublist(0, 8), signature)) {
      throw const FormatException('Invalid plate PNG.');
    }
    final header = ByteData.sublistView(bytes);
    final width = header.getUint32(16), height = header.getUint32(20);
    if (width < 1 || height < 1 || width > 768 || height > 768) {
      throw const FormatException('Invalid plate mask dimensions.');
    }
    final mask = img.decodePng(bytes);
    if (mask == null || mask.numChannels != 4) {
      throw const FormatException('Plate mask must contain RGBA transparency.');
    }
    final cropWidth = bounds[2] * (size[0] as int);
    final cropHeight = bounds[3] * (size[1] as int);
    final aspect = cropWidth / cropHeight;
    if ((width / height - aspect).abs() > aspect * .03 + 1 / height) {
      throw const FormatException('Plate mask does not match its crop.');
    }
    plates.add({'bounds': bounds, 'mask': encoded, 'aspect': aspect});
  }
  return plates;
}
