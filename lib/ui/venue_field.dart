import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../data/models.dart';
import '../services/venue_location.dart';
import 'geoapify_attribution.dart';
import 'location_access.dart';
import 'theme.dart';

/// Restaurant suggestions anchored to the meal's existing venue field.
class VenueField extends StatefulWidget {
  const VenueField({
    super.key,
    required this.app,
    required this.memory,
    required this.controller,
    required this.onChanged,
    required this.onSelected,
    this.locate = currentVenueLocation,
  });

  final MorslController app;
  final Memory memory;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<Map<String, dynamic>> onSelected;
  final Future<VenueLocation> Function() locate;

  @override
  State<VenueField> createState() => _VenueFieldState();
}

class _VenueFieldState extends State<VenueField> {
  final focus = FocusNode();
  final portal = OverlayPortalController();
  final link = LayerLink();
  final fieldKey = GlobalKey();
  final tapGroup = Object();
  final scroll = ScrollController();
  Timer? debounce;
  int version = 0, highlighted = -1;
  bool loading = false, searched = false, needsLocation = false;
  String? error;
  List<Map<String, dynamic>> candidates = [];
  VenueLocation? origin;
  Future<VenueLocation>? locating;

  bool get editable =>
      widget.memory.ownsMeal &&
      widget.app.canMutate &&
      widget.app.scope == widget.memory.scope;

  @override
  void initState() {
    super.initState();
    rememberOrigin();
    focus.addListener(focusChanged);
    focus.onKeyEvent = handleKey;
  }

  void rememberOrigin() {
    final lat = widget.memory.latitude, lng = widget.memory.longitude;
    if (origin == null &&
        lat != null &&
        lng != null &&
        lat.isFinite &&
        lng.isFinite &&
        lat.abs() <= 90 &&
        lng.abs() <= 180) {
      origin = (latitude: lat, longitude: lng);
    }
  }

  @override
  void didUpdateWidget(covariant VenueField oldWidget) {
    super.didUpdateWidget(oldWidget);
    rememberOrigin();
    if (!editable) {
      version++;
      debounce?.cancel();
      portal.hide();
    }
  }

  void focusChanged() {
    if (!focus.hasFocus) {
      debounce?.cancel();
      version++;
      portal.hide();
      setState(() => loading = false);
    } else if (editable && widget.controller.text.trim().length >= 2) {
      queueSearch();
    }
  }

  void changed(String value) {
    rememberOrigin();
    widget.onChanged(value);
    queueSearch();
  }

  void queueSearch() {
    debounce?.cancel();
    version++;
    final eligible = editable && widget.controller.text.trim().length >= 2;
    setState(() {
      candidates = [];
      highlighted = -1;
      searched = false;
      loading = eligible;
      error = null;
      needsLocation = false;
    });
    if (!eligible || !focus.hasFocus) {
      portal.hide();
      return;
    }
    portal.show();
    debounce = Timer(const Duration(milliseconds: 450), search);
  }

  Future<void> search() async {
    debounce?.cancel();
    final query = widget.controller.text.trim();
    if (!editable || !focus.hasFocus || query.length < 2) return;
    final request = ++version;
    setState(() {
      loading = true;
      error = null;
      needsLocation = false;
    });
    portal.show();
    try {
      if (!widget.app.cloud.configured) {
        throw StateError(
          'Restaurant search is unavailable. You can keep the name without a map pin.',
        );
      }
      if (!widget.app.online) {
        throw StateError(
          'Connect to the internet to find restaurants. The name will still be saved.',
        );
      }
      rememberOrigin();
      if (origin == null) {
        locating ??= widget.locate();
        try {
          origin = await locating!;
        } finally {
          locating = null;
        }
      }
      if (!mounted || request != version || !editable) return;
      final results = await widget.app.cloud.venues(
        origin!.latitude,
        origin!.longitude,
        query: query,
      );
      if (!mounted || request != version || !editable) return;
      setState(() {
        candidates = results;
        searched = true;
      });
    } catch (failure) {
      if (!mounted || request != version) return;
      setState(() {
        needsLocation = failure is VenueLocationException;
        error = failure is StateError
            ? failure.message.toString()
            : 'Restaurant search is unavailable. Try again or keep just the name.';
      });
    } finally {
      if (mounted && request == version) setState(() => loading = false);
    }
  }

  void select(Map<String, dynamic> candidate) {
    if (!editable) return;
    final lat = candidate['latitude'], lng = candidate['longitude'];
    if (lat is! num ||
        lng is! num ||
        !lat.isFinite ||
        !lng.isFinite ||
        lat.abs() > 90 ||
        lng.abs() > 180) {
      setState(
        () => error =
            'This restaurant has no map location. Choose another branch or keep just the name.',
      );
      return;
    }
    version++;
    debounce?.cancel();
    widget.controller.text =
        candidate['name'] as String? ?? 'Restaurant or cafe';
    widget.onSelected(candidate);
    focus.unfocus();
    portal.hide();
  }

  Future<void> retry() async {
    if (needsLocation && !await ensureLocationAccess(context)) return;
    if (mounted && editable) {
      focus.requestFocus();
      await search();
    }
  }

  KeyEventResult handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !portal.isShowing)
      return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      portal.hide();
      return KeyEventResult.handled;
    }
    if (candidates.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        highlighted =
            (highlighted +
                (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1)) %
            candidates.length;
      });
      if (scroll.hasClients) {
        scroll.jumpTo(
          (highlighted * 72.0).clamp(0, scroll.position.maxScrollExtent),
        );
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && highlighted >= 0) {
      select(candidates[highlighted]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    debounce?.cancel();
    version++;
    focus.removeListener(focusChanged);
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  Widget suggestionOverlay(BuildContext context) {
    final box = fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return const SizedBox.shrink();
    final media = MediaQuery.of(context);
    final top = box.localToGlobal(Offset.zero).dy;
    final below =
        media.size.height -
        math.max(media.viewInsets.bottom, media.padding.bottom) -
        top -
        box.size.height -
        8;
    final above = top - media.padding.top - 8;
    final openAbove = below < 160 && above > below;
    final height = math.min(320.0, openAbove ? above : below);
    if (height < 48) return const SizedBox.shrink();
    return Positioned(
      width: box.size.width,
      child: CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: openAbove ? Alignment.topLeft : Alignment.bottomLeft,
        followerAnchor: openAbove ? Alignment.bottomLeft : Alignment.topLeft,
        offset: Offset(0, openAbove ? -4 : 4),
        child: TextFieldTapRegion(
          groupId: tapGroup,
          child: Material(
            key: const ValueKey('venue-suggestions'),
            color: Palette.paper,
            elevation: 4,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height),
              child: ListView(
                controller: scroll,
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  if (loading)
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Semantics(
                        liveRegion: true,
                        child: const Text('Finding restaurants…'),
                      ),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            error!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Palette.terracotta,
                            ),
                          ),
                          TextButton(
                            onPressed: retry,
                            child: Text(
                              needsLocation ? 'Enable location' : 'Try again',
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!loading && searched && candidates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No matching restaurants. Try the branch or mall name.',
                        style: TextStyle(fontSize: 12, color: Palette.muted),
                      ),
                    ),
                  for (var i = 0; i < candidates.length; i++)
                    ListTile(
                      leading: const Icon(Icons.place_outlined, size: 20),
                      title: Text(
                        candidates[i]['name'] as String? ??
                            'Restaurant or cafe',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        candidates[i]['address'] as String? ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: highlighted == i,
                      selectedTileColor: Palette.sage,
                      onTap: () => select(candidates[i]),
                    ),
                  if (!loading) ...[
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.edit_outlined, size: 20),
                      title: const Text('Keep just the name'),
                      subtitle: const Text('Saved without a map pin'),
                      onTap: () {
                        widget.onChanged(widget.controller.text);
                        focus.unfocus();
                      },
                    ),
                  ],
                  if (candidates.isNotEmpty) const GeoapifyAttribution(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: portal,
    overlayChildBuilder: suggestionOverlay,
    child: CompositedTransformTarget(
      link: link,
      child: TextField(
        key: fieldKey,
        groupId: tapGroup,
        controller: widget.controller,
        focusNode: focus,
        readOnly: !editable,
        onChanged: changed,
        onSubmitted: (_) => search(),
        onEditingComplete: () {},
        onTapOutside: (_) => focus.unfocus(),
        textInputAction: TextInputAction.search,
        maxLength: 120,
        decoration: InputDecoration(
          hintText: 'A restaurant, Home, Picnic…',
          counterText: '',
          prefixIcon: const Icon(Icons.place_outlined, size: 19),
          suffixIcon: loading && focus.hasFocus
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : widget.memory.locationConfirmed
              ? const Icon(
                  Icons.check_circle_outline,
                  color: Palette.forest,
                  semanticLabel: 'Location confirmed',
                )
              : null,
        ),
      ),
    ),
  );
}
