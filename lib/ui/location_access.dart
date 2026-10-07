import 'package:flutter/material.dart';

import '../services/venue_location.dart';

Future<bool> ensureLocationAccess(
  BuildContext context, {
  LocationAccessService service = const LocationAccessService(),
}) async {
  try {
    final status = await service.check();
    if (!context.mounted) return false;
    if (status == LocationAccessStatus.ready) return true;
    return await showDialog<bool>(
          context: context,
          builder: (_) =>
              LocationAccessPrompt(service: service, initialStatus: status),
        ) ??
        false;
  } catch (_) {
    // Optional location must never prevent adding a photo.
    return false;
  }
}

class LocationAccessPrompt extends StatefulWidget {
  const LocationAccessPrompt({
    super.key,
    required this.service,
    required this.initialStatus,
  });
  final LocationAccessService service;
  final LocationAccessStatus initialStatus;

  @override
  State<LocationAccessPrompt> createState() => _LocationAccessPromptState();
}

class _LocationAccessPromptState extends State<LocationAccessPrompt>
    with WidgetsBindingObserver {
  late LocationAccessStatus status;
  bool busy = false,
      openedSettings = false,
      pendingResume = false,
      closing = false;
  String? error;

  @override
  void initState() {
    super.initState();
    status = widget.initialStatus;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && openedSettings) {
      if (busy) {
        pendingResume = true;
      } else {
        checkAfterSettings();
      }
    }
  }

  Future<void> checkAfterSettings() async {
    if (!mounted || closing || busy) return;
    setState(() => busy = true);
    try {
      var next = await widget.service.check();
      if (!mounted || closing) return;
      if (next == LocationAccessStatus.permissionNeeded) {
        next = await widget.service.requestPermission();
      }
      if (!mounted || closing) return;
      if (next == LocationAccessStatus.ready) {
        finish(true);
        return;
      }
      setState(() {
        status = next;
        openedSettings = false;
      });
    } catch (_) {
      if (mounted && !closing) {
        setState(
          () => error =
              'Could not check location. Try again or continue without it.',
        );
      }
    } finally {
      if (mounted && !closing) setState(() => busy = false);
    }
  }

  Future<void> enable() async {
    if (closing || busy) return;
    if (openedSettings) {
      await checkAfterSettings();
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await widget.service.check();
      if (!mounted || closing) return;
      if (next == LocationAccessStatus.ready) {
        finish(true);
        return;
      }
      if (next == LocationAccessStatus.permissionNeeded) {
        final result = await widget.service.requestPermission();
        if (!mounted || closing) return;
        if (result == LocationAccessStatus.ready) {
          finish(true);
          return;
        }
        setState(() => status = result);
      } else {
        setState(() => status = next);
        openedSettings = true;
        final opened = await widget.service.openSettings(next);
        if (!mounted || closing) return;
        if (!opened) {
          setState(() {
            openedSettings = false;
            error =
                'Open your phone’s settings to enable location, or continue without it.';
          });
        }
      }
    } catch (_) {
      if (mounted && !closing) {
        setState(
          () => error =
              'Could not enable location. Try again or continue without it.',
        );
      }
    } finally {
      if (mounted && !closing) {
        setState(() => busy = false);
        if (pendingResume) {
          pendingResume = false;
          checkAfterSettings();
        }
      }
    }
  }

  void finish(bool ready) {
    if (!mounted || closing || ModalRoute.of(context)?.isCurrent != true) return;
    closing = true;
    Navigator.pop(context, ready);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Find restaurants nearby'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(switch (status) {
          LocationAccessStatus.serviceOff =>
            'Turn on your phone’s location to find restaurants near your meal.',
          LocationAccessStatus.permissionBlocked =>
            'Allow location for morsl in your phone’s app settings to find nearby restaurants.',
          _ => 'Allow morsl to use your location to find nearby restaurants.',
        }),
        const SizedBox(height: 12),
        const Text(
          'You can still add photos and save venue names without location.',
        ),
        if (error != null) ...[const SizedBox(height: 12), Text(error!)],
      ],
    ),
    actions: [
      TextButton(onPressed: () => finish(false), child: const Text('Not now')),
      FilledButton(
        onPressed: busy ? null : enable,
        child: Text(
          busy
              ? 'Checking…'
              : openedSettings
              ? 'Check again'
              : switch (status) {
                  LocationAccessStatus.serviceOff => 'Turn on location',
                  LocationAccessStatus.permissionBlocked => 'Open app settings',
                  _ => 'Allow location',
                },
        ),
      ),
    ],
  );
}
