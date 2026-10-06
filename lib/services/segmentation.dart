import '../data/models.dart';

abstract interface class SegmentationEngine {
  Future<bool> available();
  Future<String> process(String original, String output);
  String get runtime;
}

abstract interface class MultiSubjectSegmentationEngine {
  Future<List<Plate>> subjects(
    String original,
    String directory, {
    Plate? region,
  });
}

/// Every remote extraction path must enforce the user's upload choice.
abstract interface class RemoteSegmentationEngine {
  bool get authenticated;
  bool get uploadsAllowed;
  set uploadsAllowed(bool value);
}
