import 'package:geolocator/geolocator.dart';

typedef VenueLocation = ({double latitude, double longitude});

enum LocationAccessStatus {
  ready,
  serviceOff,
  permissionNeeded,
  permissionBlocked,
}

class LocationAccessService {
  const LocationAccessService();

  Future<LocationAccessStatus> check() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccessStatus.serviceOff;
    }
    final permission = await Geolocator.checkPermission();
    return switch (permission) {
      LocationPermission.deniedForever =>
        LocationAccessStatus.permissionBlocked,
      LocationPermission.denied || LocationPermission.unableToDetermine =>
        LocationAccessStatus.permissionNeeded,
      _ => LocationAccessStatus.ready,
    };
  }

  Future<LocationAccessStatus> requestPermission() async {
    await Geolocator.requestPermission();
    return check();
  }

  Future<bool> openSettings(LocationAccessStatus status) =>
      status == LocationAccessStatus.serviceOff
      ? Geolocator.openLocationSettings()
      : Geolocator.openAppSettings();
}

class VenueLocationException extends StateError {
  VenueLocationException(this.status, super.message);
  final LocationAccessStatus status;
}

Future<VenueLocation> currentVenueLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw VenueLocationException(
      LocationAccessStatus.serviceOff,
      'Turn on device location to find nearby restaurants.',
    );
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw VenueLocationException(
      permission == LocationPermission.deniedForever
          ? LocationAccessStatus.permissionBlocked
          : LocationAccessStatus.permissionNeeded,
      'Allow location access to find nearby restaurants. You can also save just the venue name.',
    );
  }
  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.medium,
      timeLimit: Duration(seconds: 12),
    ),
  );
  return (latitude: position.latitude, longitude: position.longitude);
}
