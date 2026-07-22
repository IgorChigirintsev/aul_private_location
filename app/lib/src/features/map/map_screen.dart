import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../domain/place.dart';
import '../../theme.dart';
import '../../tracking/geofence_engine.dart' show GeofenceKind;
import '../notifications/notification_service.dart';
import '../realtime/connection_banner.dart';
import '../realtime/realtime_controller.dart';
import '../retention/arrival_monitor.dart';
import '../retention/retention_controller.dart';
import 'accuracy.dart';
import 'freshness.dart';
import 'geofence_feed.dart';
import 'member_position_store.dart';
import 'member_positions.dart';
import 'member_positions_poller.dart';

/// OpenFreeMap "positron" — the same muted, key-less light basemap the web
/// dashboard uses. Override the const to point at a self-hosted style (mirrors
/// the web's VITE_TILES_STYLE); it works with a plain HTTP style URL, no key.
const String kMapStyleUrl = 'https://tiles.openfreemap.org/styles/positron';

/// Geofence circle colours — the same green fill/outline the web MapView uses
/// (#155E4A) so a place looks the same on both clients; the draft circle uses
/// the accent terracotta (#B4632A) with a dashed outline while editing.
const String _kGeofenceColor = '#155E4A';
const String _kDraftColor = '#B4632A';

/// The member accuracy halo: a cool blue, deliberately unlike the geofence green
/// and the draft orange, because it means something different from both — not a
/// place someone chose, but how sure the phone is about where it is.
const String _kAccuracyColor = '#2563EB';

/// The SOS pulse colour — the same danger red the web marker uses
/// (`.aul-marker--sos`, #dc2626) so a person in distress reads the same on both
/// clients. Reserved for SOS per the design system.
const String _kSosColor = '#DC2626';

/// Below this radius (metres) the halo is not drawn: it would be smaller than
/// the marker sitting on it, so it would add clutter and say nothing. Shared
/// with the members-list "±N" label (see accuracy.dart) so the halo threshold
/// and the printed figure always agree, and in step with the web's threshold so
/// both clients hide the same halos.
const double _kAccuracyMinMeters = kAccuracyMinDrawMeters;

/// Geofence-radius slider bounds (metres) — matches the web PlacesPanel
/// (min 50, max 1000, step 10, default 150).
const double _kRadiusMin = 50;
const double _kRadiusMax = 1000;
const double _kRadiusDefault = 150;

/// The slide-up member sheet's resting heights, as fractions of the screen — a
/// Google-Maps-style peek / half / full. Peek shows the grab handle + header;
/// the web's mobile sheet uses the same three-stop idea (0.16 / 0.52 / 0.9).
const double _kSheetPeek = 0.14;
const double _kSheetHalf = 0.5;
const double _kSheetFull = 0.9;

/// Full-screen live map of a circle: one marker per device at its decrypted
/// [MemberPosition], plus the circle's encrypted PLACES drawn as true-metre
/// geofence circles (a GeoJSON fill+line whose radius is ground distance, like
/// the web `geoCircleRing`) with a name label, and an add/edit editor (tap the
/// map to set the centre, drag the radius slider, name it, save/delete). Names +
/// coordinates are sealed under K_c before they leave the device — the server
/// only ever relays ciphertext.
///
/// The MapLibre surface renders only on a device, so there is no widget test for
/// it — the decode/join logic lives in the plain [buildMemberPositions] pipeline
/// and the [PlaceCodec], which are unit-tested separately.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({
    super.key,
    required this.circleId,
    this.focusLat,
    this.focusLng,
  });

  final String circleId;

  /// An optional coordinate to centre + zoom on as soon as the map is ready —
  /// set when a member row in the list is tapped, so opening the map lands on
  /// that member instead of the whole-circle fit. Both are null (the default) or
  /// both are set. Mirrors the web's `useMapFocus` flyTo.
  final double? focusLat;
  final double? focusLng;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  MapLibreMapController? _map;
  MemberPositionsPoller? _poller;

  /// The store → this screen (what to draw).
  StreamSubscription<Map<String, MemberPosition>>? _sub;

  /// The poller → the store (one of the two producers feeding it).
  StreamSubscription<Map<String, MemberPosition>>? _pollSub;

  /// Set only when this screen had to build its OWN store — i.e. it was opened
  /// for a circle other than the selected one, which the shared store does not
  /// speak for. Owned here, so disposed here.
  MemberPositionStore? _ownStore;

  bool _styleLoaded = false;
  bool _layersAdded = false;
  bool _received = false;
  bool _didFit = false;
  bool _syncing = false;
  bool _pending = false;

  Map<String, MemberPosition> _positions = const {};
  final Map<String, Symbol> _symbols = {};
  final Set<String> _imagesAdded = {};

  // --- SOS raiser highlight (a red pulse around a member in distress) ---

  /// Device ids with an ACTIVE SOS right now, from the decrypted alert list
  /// (each alert carries the raising device). Their markers pulse red and never
  /// dim, so a person in distress is unmistakable for everyone watching; cleared
  /// when the SOS is resolved. Mirrors the web `setMarkerSos`.
  Set<String> _sosDeviceIds = const {};

  /// Drives the red pulse ring. Runs only while a raiser is on the map, at a low
  /// frame rate (an emergency highlight, not a 60 fps loop) — a platform call per
  /// tick, so [_pulseBusy] drops a tick that would overlap the previous one.
  Timer? _sosPulseTimer;
  double _sosPhase = 0;
  bool _pulseBusy = false;

  /// A one-shot camera target from a tapped member row, applied once the map is
  /// ready. Null unless [MapScreen.focusLat]/[MapScreen.focusLng] were passed.
  LatLng? _pendingFocus;

  // --- geofence feed (who is inside which place, + recent crossings) ---

  /// Computed on this device from decrypted positions vs decrypted places — the
  /// server has neither, so nobody else could compute it. Recomputed on every
  /// poll tick, which also ages stale positions out of presence.
  final GeofenceFeedController _feedController = GeofenceFeedController();

  /// The current picture, as a listenable so the open sheet stays live without
  /// rebuilding the map underneath it.
  final ValueNotifier<GeofenceFeed> _feed = ValueNotifier(const GeofenceFeed());

  /// Fires an in-app "member arrived" notification for OTHER members' geofence
  /// entries seen on the live position stream while this screen is open. Own-fix
  /// arrivals belong to the background isolate (see [ArrivalMonitor.onOwnFix]);
  /// this only ever calls [ArrivalMonitor.onMemberArrival], which is the
  /// foreground's to run. Built lazily in [initState] from the shared service.
  late final ArrivalMonitor _arrivalMonitor;

  /// Drives the slide-up member sheet (Google-Maps style) so a tapped member row
  /// can collapse the sheet back to its peek after the camera flies to them.
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  // --- places / editor state ---
  List<Place> _places = const [];

  /// userId → display name, for resolving a place's `created_by` to the owner's
  /// nickname (falling back to their email). Empty until the members load, or
  /// when offline — the owner line is then simply omitted.
  Map<String, String> _ownerNames = const {};
  final TextEditingController _nameCtl = TextEditingController();
  bool _editing = false;
  String? _editId;
  int? _editVersion;
  LatLng? _draftCenter;
  double _draftRadius = _kRadiusDefault;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final ctrl = ref.read(controllerProvider.notifier);
    _arrivalMonitor = ArrivalMonitor(
      notifications: ref.read(notificationServiceProvider),
    );

    // The shared store holds the SELECTED circle's positions — that is the one
    // circle the socket is subscribed to. Opened for any other circle, this
    // screen uses a store of its own, fed by the poller alone: it must never
    // render another circle's members, and must never write this circle's members
    // into the store the rest of the app reads. Every call site passes the
    // selected circle today; this keeps that a fact rather than a hope.
    final selectedId = ref.read(controllerProvider).selectedCircle?.id;
    final store = widget.circleId == selectedId
        ? ref.read(memberPositionStoreProvider)
        : (_ownStore = MemberPositionStore());

    // Both producers feed that store, and the map renders whatever it holds. The
    // socket pushes fixes the moment they happen; the poller sweeps up whatever
    // the socket missed (it was down, backgrounded, or the server is too old to
    // have the endpoint) and carries the roster/profile/precision join the socket
    // has no way to send. The store's newest-per-device rule is what makes
    // running both at once safe.
    _positions = store.positions; // may already be warm from the socket
    _received = _positions.isNotEmpty;
    _sub = store.stream.listen(_onPositions);

    final poller = MemberPositionsPoller(
      fetch: () => ctrl.loadMemberPositions(widget.circleId),
    );
    _pollSub = poller.stream.listen(store.bulk);
    poller.start();
    _poller = poller;

    // A member row asked us to land on them — remember it until the map is ready,
    // and suppress the whole-circle fit so it doesn't yank the camera away again.
    final lat = widget.focusLat, lng = widget.focusLng;
    if (lat != null && lng != null) {
      _pendingFocus = LatLng(lat, lng);
      _didFit = true;
    }

    unawaited(_loadPlaces());
    unawaited(_loadSos());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pollSub?.cancel();
    _poller?.dispose();
    _stopSosPulse();
    // Only ours to close; the shared one outlives this screen.
    _ownStore?.dispose();
    _nameCtl.dispose();
    _feed.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  void _onPositions(Map<String, MemberPosition> positions) {
    _positions = positions;
    _recomputeFeed();
    if (mounted) setState(() => _received = true);
    unawaited(_sync());
    // A raiser may have moved — keep their pulse ring under their pin.
    unawaited(_syncSos());
  }

  /// Refreshes the geofence picture from the latest positions + places. Called on
  /// every poll tick (not only when something moved) so a position that goes
  /// stale ages out of presence on its own.
  void _recomputeFeed() {
    _feed.value = _feedController.update(
      _positions,
      _places,
      DateTime.now(),
      // The ETA "on the way" rows are gated on the same arrival opt-in the web
      // feed uses (operator kill-switch AND the user's own opt-in).
      arrivalActive: ref.read(retentionProvider).arrivalActive,
    );
    // A member other than me just crossed INTO a place — surface it in-app while
    // this screen is open. The arriving member's OWN device already relays the
    // crossing to the whole circle over `/notify` (background isolate), so a
    // closed app is the push pipeline's job; this covers the foreground, where
    // FCM would not reliably deliver anyway.
    _notifyMemberArrivals(_feedController.lastCrossings);
  }

  /// Fires a local "member arrived" notification for each OTHER member's ENTER
  /// crossing on the most recent feed tick, behind the user's arrival opt-in. My
  /// own crossings are the background isolate's to announce (`onOwnFix`), so they
  /// are skipped here — announcing them again would double up.
  void _notifyMemberArrivals(List<MemberCrossing> crossings) {
    if (crossings.isEmpty) return;
    if (!ref.read(retentionProvider).arrivalActive) return;
    if (!mounted) return;
    final myUserId = ref.read(controllerProvider).userId;
    final l10n = AppLocalizations.of(context);
    for (final c in crossings) {
      if (c.kind != GeofenceKind.enter) continue;
      final userId = _positions[c.deviceId]?.userId;
      if (userId == null || userId == myUserId) continue;
      unawaited(
        _arrivalMonitor.onMemberArrival(
          memberName: c.label,
          placeName: c.placeName,
          active: true, // already gated on arrivalActive above
          l10n: l10n,
        ),
      );
    }
  }

  void _onMapCreated(MapLibreMapController controller) => _map = controller;

  void _onStyleLoaded() {
    _styleLoaded = true;
    unawaited(_onStyleReady());
  }

  /// After the style loads: add the geofence/label/draft sources+layers once,
  /// then paint the current places, draft, and member positions.
  Future<void> _onStyleReady() async {
    final map = _map;
    if (map == null) return;
    await _ensureLayers(map);
    // Before painting positions: a member row asked us to land on them, and the
    // auto-fit is already suppressed for it (see initState).
    await _applyFocus(map);
    await _syncPlaces();
    await _syncDraft();
    await _syncSos();
    await _sync();
  }

  /// Centres + zooms on the coordinate a tapped member row handed us, once. A
  /// no-op when nothing was requested. Mirrors the web `useMapFocus` flyTo.
  Future<void> _applyFocus(MapLibreMapController map) async {
    final target = _pendingFocus;
    if (target == null) return;
    _pendingFocus = null;
    await map.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
  }

  /// Tapping the map while editing sets the draft place's centre.
  void _onMapClick(math.Point<double> point, LatLng coordinates) {
    if (!_editing) return;
    setState(() => _draftCenter = coordinates);
    unawaited(_syncDraft());
  }

  /// Serialised so overlapping poll ticks + the style-load callback never race
  /// on the async symbol/image calls. A tick arriving mid-sync sets [_pending]
  /// so the freshest snapshot is always applied.
  Future<void> _sync() async {
    final map = _map;
    if (map == null || !_styleLoaded) return;
    if (_syncing) {
      _pending = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _pending = false;
        await _applyPositions(map);
      } while (_pending);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _applyPositions(MapLibreMapController map) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final snapshot = _positions;
    // Evaluated once per repaint against the current clock, so a marker whose fix
    // has aged past the freshness threshold reads as not-live. Repaints ride the
    // poll tick (every ~17 s), which is what makes a dot go dim on its own when a
    // phone (or the server) drops off, rather than sitting fresh-looking forever.
    final now = DateTime.now();
    // The halos ride on one GeoJSON source rather than per-marker annotations, so
    // a member who moves, pauses, or drops out repaints with the same snapshot as
    // their pin and can never leave a stale ring behind.
    if (_layersAdded) {
      await map.setGeoJsonSource(
        'member-accuracy',
        positionsToAccuracyCircles(snapshot.values),
      );
    }
    for (final pos in snapshot.values) {
      // The paused state is part of the image identity: a live and a greyed-out
      // marker are two different images, so toggling sharing swaps the icon
      // instead of reusing a cached live one. The SOS state is part of it too — a
      // raiser's pin gains a red ring, so raising/resolving an SOS swaps the icon
      // rather than reusing the cached normal one.
      final sos = _sosDeviceIds.contains(pos.deviceId);
      final imageName =
          'marker_${pos.deviceId}${pos.isPaused ? '_paused' : ''}${sos ? '_sos' : ''}';
      if (!_imagesAdded.contains(imageName)) {
        try {
          final bytes = await _renderMarker(
            avatar: pos.avatarBytes,
            initial: pos.initial,
            paused: pos.isPaused,
            sos: sos,
          );
          await map.addImage(imageName, bytes);
          _imagesAdded.add(imageName);
        } catch (_) {
          // Fall back to a bare label if image generation/upload fails.
        }
      }
      final geometry = LatLng(pos.fix.lat, pos.fix.lng);
      final existing = _symbols[pos.deviceId];
      if (existing == null) {
        _symbols[pos.deviceId] = await map.addSymbol(
          _optionsFor(pos, geometry, imageName, l10n, now),
        );
      } else {
        // Full options, not just the geometry: a member who pauses, renames, or
        // goes stale between ticks must repaint icon/opacity/label, not just move.
        await map.updateSymbol(
          existing,
          _optionsFor(pos, geometry, imageName, l10n, now),
        );
      }
    }
    // Drop markers for devices that dropped out of the snapshot.
    final live = snapshot.keys.toSet();
    for (final id in _symbols.keys.toList()) {
      if (!live.contains(id)) {
        final s = _symbols.remove(id);
        if (s != null) await map.removeSymbol(s);
      }
    }
    _maybeFit(map, snapshot);
  }

  SymbolOptions _optionsFor(
    MemberPosition pos,
    LatLng geometry,
    String imageName,
    AppLocalizations l10n,
    DateTime now,
  ) {
    final tag = pos.isPc ? l10n.mapTagPc : l10n.mapTagPhone;
    // A paused member reads as not-live: a desaturated icon at half opacity with
    // a muted grey label (mirrors the web's `filter: grayscale(1); opacity: .5`),
    // plus a "Paused" hint after the device tag. The pin stays exactly where they
    // stopped — that IS the last place they shared.
    final paused = pos.isPaused;
    // Stale but NOT paused: they never turned sharing off, we simply stopped
    // hearing from them (offline, no signal, or the realtime server is gone). The
    // pin can't be trusted as current, so it dims too — but distinctly from paused
    // (dim, not greyscaled, with a "Stale" hint), because "chose to stop" and
    // "went quiet" are different facts. Paused wins when both are true: an explicit
    // choice is the more honest thing to show.
    final stale = !paused && isStale(pos.fix.capturedAt, now);
    // A raiser in distress must never look faded: their SOS pulse beats any
    // paused/stale dimming, exactly as the web forces `.aul-marker--sos` to full
    // opacity over the greyed-out states.
    final sos = _sosDeviceIds.contains(pos.deviceId);
    final notLive = !sos && (paused || stale);
    // Battery goes on the pin itself: "why hasn't she moved" is answered by "her
    // phone is at 3%" often enough to be worth the two characters, and it saves a
    // trip to the members screen to find out. It rode in inside the sealed ping,
    // so it is null for a reporter that sends none. The freshness label stays on
    // the members screen — a label that must be re-rendered to stay true doesn't
    // belong on a map pin.
    final battery = pos.battery;
    final subtitle = [
      tag,
      if (paused) l10n.precisionPaused,
      if (stale) l10n.staleBadge,
      if (battery != null) l10n.batteryPercent(battery),
    ].join(' · ');
    return SymbolOptions(
      geometry: geometry,
      iconImage: _imagesAdded.contains(imageName) ? imageName : null,
      iconSize: 0.5,
      iconAnchor: 'bottom',
      iconOpacity: notLive ? 0.5 : 1.0,
      textField: '${pos.label}\n$subtitle',
      textSize: 12,
      textAnchor: 'top',
      textOffset: const Offset(0, 0.6),
      textColor: notLive ? '#78716C' : '#1C1917',
      textOpacity: notLive ? 0.75 : 1.0,
      textHaloColor: '#FFFFFF',
      textHaloWidth: 1.4,
      textMaxWidth: 8,
    );
  }

  void _maybeFit(
    MapLibreMapController map,
    Map<String, MemberPosition> snapshot,
  ) {
    if (_didFit || snapshot.isEmpty) return;
    _didFit = true;
    _fit(map, snapshot);
  }

  Future<void> _fit(
    MapLibreMapController map,
    Map<String, MemberPosition> snapshot,
  ) async {
    final fixes = snapshot.values.map((p) => p.fix).toList();
    var minLat = fixes.first.lat, maxLat = fixes.first.lat;
    var minLng = fixes.first.lng, maxLng = fixes.first.lng;
    for (final f in fixes) {
      minLat = f.lat < minLat ? f.lat : minLat;
      maxLat = f.lat > maxLat ? f.lat : maxLat;
      minLng = f.lng < minLng ? f.lng : minLng;
      maxLng = f.lng > maxLng ? f.lng : maxLng;
    }
    // A single member (or a near-degenerate spread) reads better as a centred
    // zoom than a zero-area fitBounds.
    if (fixes.length == 1 ||
        (maxLat - minLat < 1e-4 && maxLng - minLng < 1e-4)) {
      await map.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2),
          14,
        ),
      );
      return;
    }
    await map.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        left: 60,
        right: 60,
        top: 110,
        bottom: 120,
      ),
    );
  }

  Future<void> _recenter() async {
    _didFit = false;
    await _poller?.refresh();
    final map = _map;
    if (map != null && _positions.isNotEmpty) _maybeFit(map, _positions);
  }

  // --- on-map camera controls (mirror the web Dashboard's reset-north +
  //     recenter-on-me buttons; see web/src/store/mapFocus.ts) ---

  /// Rotates the camera back to north-up: bearing AND pitch to 0, keeping the
  /// current centre/zoom. Mirrors the web `map.easeTo({ bearing: 0, pitch: 0 })`.
  /// Rebuilding a [CameraPosition] from the tracked one (bearing/tilt default to
  /// 0) resets both in one animation; a bearing-only fallback covers the rare
  /// window before [MapLibreMap.trackCameraPosition] has reported a frame.
  Future<void> _resetNorth() async {
    final map = _map;
    if (map == null) return;
    final cam = map.cameraPosition;
    if (cam == null) {
      await map.animateCamera(CameraUpdate.bearingTo(0));
      return;
    }
    await map.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: cam.target, zoom: cam.zoom),
      ),
    );
  }

  /// This account's OWN freshest position across its devices, or null when we
  /// have no decodable fix for the current user yet (so the recenter button is a
  /// no-op / disabled). Positions arrive keyed by DEVICE; [positionsByUser]
  /// collapses a member's phone + laptop to their most recent capture — the same
  /// "me across my devices" rule the web `recenterOnMe` uses. This is the current
  /// user's own marker on the map, NOT the phone's raw GPS.
  MemberPosition? _selfPosition(String? myUserId) {
    if (myUserId == null) return null;
    return positionsByUser(_positions)[myUserId];
  }

  /// Flies the camera to the current user's own latest shared position at a
  /// street-level zoom. Mirrors the web `useMapFocus.focus` flyTo (zoom 15).
  Future<void> _recenterOnMe(MemberPosition self) async {
    final map = _map;
    if (map == null) return;
    await map.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(self.fix.lat, self.fix.lng), 15),
    );
  }

  /// Flies to a member picked from the slide-up list, then collapses the sheet
  /// back to its peek so the pin it landed on is visible. Mirrors the web
  /// members-panel row tap (`useMapFocus.focus`).
  Future<void> _focusMember(MemberPosition m) async {
    final map = _map;
    if (map != null) {
      await map.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(m.fix.lat, m.fix.lng), 15),
      );
    }
    if (_sheetController.isAttached) {
      unawaited(
        _sheetController.animateTo(
          _kSheetPeek,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  // --- places rendering (geofence circles + labels) ---

  /// Adds the geofence, label, and draft sources+layers once. The fill/line/
  /// symbol layers are separate from the member-marker annotation manager, so
  /// they never disturb the live position symbols.
  Future<void> _ensureLayers(MapLibreMapController map) async {
    if (_layersAdded) return;
    // FIRST, so every later layer (and the marker symbols) draws over it: the
    // halo is context for a marker, never a thing in its own right.
    await map.addGeoJsonSource('member-accuracy', _emptyFc());
    await map.addFillLayer(
      'member-accuracy',
      'member-accuracy-fill',
      FillLayerProperties(fillColor: _kAccuracyColor, fillOpacity: 0.10),
    );
    await map.addLineLayer(
      'member-accuracy',
      'member-accuracy-line',
      LineLayerProperties(
        lineColor: _kAccuracyColor,
        lineWidth: 1,
        lineOpacity: 0.35,
      ),
    );
    // The SOS pulse ring: a red circle under a raiser's pin whose radius +
    // opacity are animated by [_startSosPulse]. A screen-pixel circle (not a
    // metre ring) because it is a highlight, not a measurement — it should read
    // the same size at every zoom. Added here so it sits above the halo but under
    // the member marker symbols (which the annotation manager draws on top).
    await map.addGeoJsonSource('sos-pulse', _emptyFc());
    await map.addCircleLayer(
      'sos-pulse',
      'sos-pulse-ring',
      const CircleLayerProperties(
        circleColor: _kSosColor,
        circleOpacity: 0,
        circleRadius: 0,
        circleStrokeColor: _kSosColor,
        circleStrokeWidth: 0,
      ),
    );
    await map.addGeoJsonSource('places-geofence', _emptyFc());
    await map.addFillLayer(
      'places-geofence',
      'places-geofence-fill',
      FillLayerProperties(fillColor: _kGeofenceColor, fillOpacity: 0.08),
    );
    await map.addLineLayer(
      'places-geofence',
      'places-geofence-line',
      LineLayerProperties(
        lineColor: _kGeofenceColor,
        lineWidth: 1.5,
        lineOpacity: 0.5,
      ),
    );
    await map.addGeoJsonSource('places-labels', _emptyFc());
    await map.addSymbolLayer(
      'places-labels',
      'places-label',
      SymbolLayerProperties(
        textField: '{name}',
        textSize: 12,
        textColor: _kGeofenceColor,
        textHaloColor: '#FFFFFF',
        textHaloWidth: 1.4,
        textAnchor: 'top',
        textOffset: const [0, 0.6],
      ),
    );
    // The owner's nickname, small and secondary, on its own layer under the name:
    // one symbol layer cannot mix two text sizes. Places with no known creator
    // carry an empty `owner`, which renders nothing. The NAME came out of the
    // sealed blob; the owner is server metadata (created_by) resolved to a nick.
    await map.addSymbolLayer(
      'places-labels',
      'places-label-owner',
      SymbolLayerProperties(
        textField: '{owner}',
        textSize: 10,
        textColor: '#78716C',
        textHaloColor: '#FFFFFF',
        textHaloWidth: 1.2,
        textAnchor: 'top',
        textOffset: const [0, 2.0],
      ),
    );
    await map.addGeoJsonSource('places-draft', _emptyFc());
    await map.addFillLayer(
      'places-draft',
      'places-draft-fill',
      FillLayerProperties(fillColor: _kDraftColor, fillOpacity: 0.1),
    );
    await map.addLineLayer(
      'places-draft',
      'places-draft-line',
      LineLayerProperties(
        lineColor: _kDraftColor,
        lineWidth: 2,
        lineDasharray: const [2, 2],
      ),
    );
    _layersAdded = true;
  }

  Future<void> _loadPlaces() async {
    final ctrl = ref.read(controllerProvider.notifier);
    final places = await ctrl.placesOf(widget.circleId);
    // Who added each place: created_by is a bare user id, so it needs the
    // circle's member profiles to become a name someone recognises.
    final owners = await ctrl.memberDisplayNames(widget.circleId);
    if (!mounted) return;
    setState(() {
      _places = places;
      _ownerNames = owners;
    });
    _recomputeFeed(); // places are half the picture — seed/refresh with them
    await _syncPlaces();
  }

  Future<void> _syncPlaces() async {
    final map = _map;
    if (map == null || !_layersAdded || !mounted) return;
    final l10n = AppLocalizations.of(context);
    await map.setGeoJsonSource('places-geofence', _placesToCircles(_places));
    await map.setGeoJsonSource(
      'places-labels',
      _placesToLabels(_places, (p) => _ownerLabel(p, l10n)),
    );
  }

  /// The "Added by …" line for a place, or null when the creator is unknown (an
  /// older server sends no created_by) or their profile hasn't loaded.
  String? _ownerLabel(Place p, AppLocalizations l10n) {
    final id = p.createdBy;
    if (id == null) return null;
    final name = _ownerNames[id];
    if (name == null || name.trim().isEmpty) return null;
    return l10n.placesAddedBy(name);
  }

  Future<void> _syncDraft() async {
    final map = _map;
    if (map == null || !_layersAdded) return;
    final c = _draftCenter;
    if (_editing && c != null) {
      await map.setGeoJsonSource(
        'places-draft',
        _circleFc(c.longitude, c.latitude, _draftRadius),
      );
    } else {
      await map.setGeoJsonSource('places-draft', _emptyFc());
    }
  }

  // --- SOS raiser pulse ---

  /// Refetches the circle's active SOS alerts and records which DEVICES are
  /// raising, so their markers pulse red. Driven on open and on the realtime
  /// `sos` signal (raised/resolved). Best-effort: a failed fetch leaves the last
  /// set untouched, and the poll behind the SOS centre reconciles it.
  Future<void> _loadSos() async {
    final alerts = await ref
        .read(controllerProvider.notifier)
        .loadSosAlerts(widget.circleId);
    if (!mounted) return;
    final ids = <String>{
      for (final a in alerts)
        if (a.deviceId != null) a.deviceId!,
    };
    if (setEquals(ids, _sosDeviceIds)) return; // nothing changed
    setState(() => _sosDeviceIds = ids);
    await _syncSos();
    await _sync(); // repaint markers so a raiser's pin stops dimming
  }

  /// Points the pulse ring at every raiser we have a live position for, and
  /// starts/stops the animation with the set. A raiser with no decodable
  /// position simply isn't drawn — there is no pin to pulse.
  Future<void> _syncSos() async {
    final map = _map;
    if (map == null || !_layersAdded) return;
    final raisers = [
      for (final p in _positions.values)
        if (_sosDeviceIds.contains(p.deviceId)) p,
    ];
    await map.setGeoJsonSource('sos-pulse', <String, dynamic>{
      'type': 'FeatureCollection',
      'features': [
        for (final p in raisers)
          {
            'type': 'Feature',
            'properties': {'id': p.deviceId},
            'geometry': {
              'type': 'Point',
              'coordinates': [p.fix.lng, p.fix.lat],
            },
          },
      ],
    });
    if (raisers.isEmpty) {
      _stopSosPulse();
    } else {
      _startSosPulse();
    }
  }

  /// Begins the red pulse loop. Idempotent — a second call while it is already
  /// running is a no-op. Low frame rate on purpose: each tick is a platform call
  /// to restyle the layer, and a distress highlight need not be a 60 fps
  /// animation.
  void _startSosPulse() {
    if (_sosPulseTimer != null) return;
    _sosPulseTimer = Timer.periodic(
      const Duration(milliseconds: 90),
      (_) => unawaited(_tickSosPulse()),
    );
  }

  void _stopSosPulse() {
    _sosPulseTimer?.cancel();
    _sosPulseTimer = null;
  }

  /// One pulse frame: the ring grows from tight+bright to wide+gone, then loops —
  /// a red heartbeat that draws the eye. Serialised via [_pulseBusy] so a slow
  /// platform call never lets two frames overlap.
  Future<void> _tickSosPulse() async {
    final map = _map;
    if (map == null || !_layersAdded || _pulseBusy) return;
    _pulseBusy = true;
    try {
      _sosPhase = (_sosPhase + 0.08) % 1.0;
      final e = Curves.easeOut.transform(_sosPhase);
      await map.setLayerProperties(
        'sos-pulse-ring',
        CircleLayerProperties(
          circleColor: _kSosColor,
          circleRadius: 6 + 22 * e,
          circleOpacity: 0.45 * (1 - e),
          circleStrokeColor: _kSosColor,
          circleStrokeWidth: 2.5 * (1 - e),
          circleStrokeOpacity: 1 - e,
        ),
      );
    } catch (_) {
      // A dropped restyle frame is invisible; the next tick tries again.
    } finally {
      _pulseBusy = false;
    }
  }

  // --- editor flow ---

  void _startAdd() {
    setState(() {
      _editing = true;
      _editId = null;
      _editVersion = null;
      _draftCenter = null;
      _draftRadius = _kRadiusDefault;
      _nameCtl.text = '';
    });
    unawaited(_syncDraft());
  }

  void _startEdit(Place p) {
    setState(() {
      _editing = true;
      _editId = p.id;
      _editVersion = p.version;
      _draftCenter = LatLng(p.lat, p.lng);
      _draftRadius = p.radius.clamp(_kRadiusMin, _kRadiusMax).toDouble();
      _nameCtl.text = p.name;
    });
    unawaited(_syncDraft());
    _map?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(p.lat, p.lng), 15));
  }

  void _cancelEdit() {
    setState(() {
      _editing = false;
      _editId = null;
      _editVersion = null;
      _draftCenter = null;
    });
    unawaited(_syncDraft());
  }

  Future<void> _save() async {
    final c = _draftCenter;
    final name = _nameCtl.text.trim();
    if (c == null || name.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(controllerProvider.notifier)
          .savePlace(
            widget.circleId,
            id: _editId,
            version: _editVersion,
            name: name,
            lat: c.latitude,
            lng: c.longitude,
            radius: _draftRadius,
          );
      _cancelEdit();
      await _loadPlaces();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.placesSaveFailed)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteEditing() async {
    final id = _editId;
    if (id == null) return;
    final name = _nameCtl.text.trim();
    if (!await _confirmDelete(name)) return;
    await ref
        .read(controllerProvider.notifier)
        .deletePlaceById(widget.circleId, id);
    _cancelEdit();
    await _loadPlaces();
  }

  Future<void> _deleteFromList(Place p) async {
    if (!await _confirmDelete(p.name)) return;
    await ref
        .read(controllerProvider.notifier)
        .deletePlaceById(widget.circleId, p.id);
    await _loadPlaces();
  }

  Future<bool> _confirmDelete(String name) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        content: Text(l10n.placesConfirmDelete(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AulColors.danger),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// The live geofence feed: who is inside a place right now, and the recent
  /// arrive/depart crossings. Mirrors the web GeofenceFeed panel; it listens to
  /// [_feed] so a poll tick updates the open sheet in place.
  void _openFeed() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: ValueListenableBuilder<GeofenceFeed>(
          valueListenable: _feed,
          builder: (ctx, feed, _) => _GeofenceFeedSheet(feed: feed),
        ),
      ),
    );
  }

  void _openPlacesList() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        final l10n = AppLocalizations.of(sheetCtx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Row(
                  children: [
                    const Icon(Icons.place_outlined, color: AulColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      l10n.placesTitle,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (_places.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: Text(
                    l10n.placesEmpty,
                    style: const TextStyle(color: AulColors.textSecondary),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in _places)
                        ListTile(
                          leading: const Icon(Icons.place_outlined),
                          title: Text(p.name),
                          // The name came out of the sealed blob; the owner line
                          // under it is server metadata (created_by) resolved to
                          // a nickname through the circle's member profiles.
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_ownerLabel(p, l10n) case final owner?)
                                Text(
                                  owner,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AulColors.textSecondary,
                                  ),
                                ),
                              Text(l10n.placesRadiusValue(p.radius.round())),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: l10n.placesSaveChanges,
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () {
                                  Navigator.pop(sheetCtx);
                                  _startEdit(p);
                                },
                              ),
                              IconButton(
                                tooltip: l10n.delete,
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: AulColors.danger,
                                ),
                                onPressed: () async {
                                  Navigator.pop(sheetCtx);
                                  await _deleteFromList(p);
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetCtx);
                    _startAdd();
                  },
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: Text(l10n.placesAddAPlace),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    // The current account's own marker, for "recenter on me". Watched (not read)
    // so the button enables the moment this user's first fix decodes; recomputed
    // on every poll/socket setState, so it always points at their latest capture.
    final myUserId = ref.watch(controllerProvider.select((s) => s.userId));
    final self = _selfPosition(myUserId);

    // The slide-up roster lists everyone with a live position, me first then by
    // name. It reads the same [_positions] the markers do, so it never needs a
    // second fetch and stays in step with the map.
    final members = positionsByUser(_positions).values.toList()
      ..sort((a, b) {
        final aMe = a.userId != null && a.userId == myUserId;
        final bMe = b.userId != null && b.userId == myUserId;
        if (aMe != bMe) return aMe ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    // Keep the on-map pills (geofence feed, empty hint) above the sheet's peek so
    // the sheet never buries them. Approximated from the full screen height — a
    // hair high is safe, it only adds margin.
    final sheetPeekPx = MediaQuery.sizeOf(context).height * _kSheetPeek;

    // Someone edited a place — refetch and redraw the geofence circles.
    ref.listen(realtimeProvider.select((r) => r.places), (_, _) {
      unawaited(_loadPlaces());
    });
    // An SOS was raised or resolved — refresh which markers should pulse red.
    ref.listen(realtimeProvider.select((r) => r.sos), (_, _) {
      unawaited(_loadSos());
    });
    // Someone changed how they share. The grey/live look of a marker is read from
    // the members list's precision_mode, NOT from the last ping (a paused member
    // sends none, so their last ping claims "precise" forever). Only a refetch
    // can see the change, so ask the poller for one now rather than leaving a
    // paused member looking live until the next tick.
    ref.listen(realtimeProvider.select((r) => r.members), (_, _) {
      unawaited(_poller?.refresh());
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.mapTitle),
        actions: [
          IconButton(
            tooltip: l10n.placesTitle,
            icon: const Icon(Icons.place_outlined),
            onPressed: _openPlacesList,
          ),
          IconButton(
            tooltip: l10n.mapRecenter,
            icon: const Icon(Icons.my_location),
            onPressed: _recenter,
          ),
        ],
      ),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: kMapStyleUrl,
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onMapClick: _onMapClick,
            initialCameraPosition: const CameraPosition(
              target: LatLng(20, 0),
              zoom: 1.5,
            ),
            trackCameraPosition: true,
            compassEnabled: true,
            // Rotation is allowed so the reset-north button has a job to undo
            // (two-finger twist); the one-tap control brings the map straight
            // back to north-up. Tilt stays off — this map is 2D, and there is no
            // pitch to reset beyond what [_resetNorth] already zeroes.
            rotateGesturesEnabled: true,
            tiltGesturesEnabled: false,
            attributionButtonPosition: AttributionButtonPosition.bottomRight,
          ),
          // The same honest, client-inferred "live updates paused" notice Home
          // carries — floated at the top of the map, where a viewer is most
          // likely to be trusting a dot's position. Collapses to nothing while the
          // socket is up.
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: const SafeArea(child: ConnectionBanner()),
          ),
          // A small vertical stack of round map controls on the right edge,
          // centred vertically so it clears the connection banner + compass
          // (top), the geofence pill / place editor (bottom), and the map
          // attribution (bottom-right) — and, on Home, the SOS FAB (bottom-
          // right). Mirrors the web Dashboard's on-map reset-north + recenter
          // controls.
          Positioned(
            top: 0,
            bottom: 0,
            right: 12,
            child: SafeArea(
              child: Align(
                alignment: Alignment.centerRight,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MapControlButton(
                      icon: Icons.explore_outlined,
                      tooltip: l10n.mapNorthUp,
                      onPressed: _resetNorth,
                    ),
                    const SizedBox(height: 12),
                    _MapControlButton(
                      icon: Icons.gps_fixed,
                      tooltip: l10n.mapRecenterOnMe,
                      // Disabled until this account has a decodable fix on the
                      // map — there is nowhere to recenter to yet.
                      onPressed: self == null
                          ? null
                          : () => _recenterOnMe(self),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!_received)
            const Center(child: CircularProgressIndicator())
          else if (_positions.isEmpty && _places.isEmpty && !_editing)
            Positioned(
              left: 0,
              right: 0,
              bottom: sheetPeekPx + 12,
              child: Center(child: _EmptyPill(text: l10n.mapEmpty)),
            ),
          // The geofence feed rides at the bottom of the map, out of the way of
          // the editor (which owns that space while a place is being drawn).
          if (!_editing)
            Positioned(
              left: 12,
              right: 12,
              bottom: sheetPeekPx + 12,
              child: ValueListenableBuilder<GeofenceFeed>(
                valueListenable: _feed,
                builder: (ctx, feed, _) => feed.isEmpty
                    ? const SizedBox.shrink()
                    : _GeofenceFeedPill(feed: feed, onTap: _openFeed),
              ),
            ),
          if (_editing)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _PlaceEditor(
                nameController: _nameCtl,
                hasCentre: _draftCenter != null,
                radius: _draftRadius,
                isEdit: _editId != null,
                busy: _busy,
                onNameChanged: () => setState(() {}),
                onRadiusChanged: (v) {
                  setState(() => _draftRadius = v);
                  unawaited(_syncDraft());
                },
                onSave: _save,
                onCancel: _busy ? null : _cancelEdit,
                onDelete: _busy ? null : _deleteEditing,
              ),
            ),
          // The Google-Maps-style slide-up roster. Hidden while editing a place
          // (the editor owns the bottom then). Drawn last so it floats above the
          // map and its pills; tap a row to fly there.
          if (_received && !_editing)
            _MemberListSheet(
              controller: _sheetController,
              members: members,
              myUserId: myUserId,
              onTapMember: _focusMember,
            ),
        ],
      ),
    );
  }
}

/// The collapsed geofence feed: a tappable summary of who is at a place right
/// now, floated over the basemap. Hidden entirely when there is nothing to say
/// (mirrors the web panel, which renders nothing when empty) — the map is for
/// the map.
class _GeofenceFeedPill extends StatelessWidget {
  const _GeofenceFeedPill({required this.feed, required this.onTap});

  final GeofenceFeed feed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      elevation: 4,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(
                Icons.pin_drop_outlined,
                size: 18,
                color: AulColors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.geofenceAtPlacesCount(feed.presence.length),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(
                Icons.expand_less,
                size: 18,
                color: AulColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The expanded geofence feed: presence now, then the recent crossings. Every
/// row here was computed on this device from decrypted positions and decrypted
/// places — the server sees neither, and never learns who is where.
class _GeofenceFeedSheet extends StatelessWidget {
  const _GeofenceFeedSheet({required this.feed});

  final GeofenceFeed feed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: [
              const Icon(Icons.pin_drop_outlined, color: AulColors.primary),
              const SizedBox(width: 8),
              Text(
                l10n.geofenceFeedTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (feed.presence.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              l10n.geofenceNobody,
              style: const TextStyle(color: AulColors.textSecondary),
            ),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in feed.presence)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined, size: 20),
                    title: Text(l10n.geofencePresenceRow(p.label, p.placeName)),
                  ),
              ],
            ),
          ),
        if (feed.etas.isNotEmpty) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              l10n.geofenceOnTheWay,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AulColors.textSecondary,
              ),
            ),
          ),
          for (final e in feed.etas)
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.navigation_outlined,
                size: 18,
                color: AulColors.primary,
              ),
              title: Text(
                l10n.geofenceEtaRow(e.label, e.placeName),
                style: const TextStyle(fontSize: 13),
              ),
              trailing: Text(
                '~${_formatEta(l10n, e.seconds)}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AulColors.textSecondary,
                ),
              ),
            ),
        ],
        if (feed.events.isNotEmpty) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              l10n.geofenceRecent,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AulColors.textSecondary,
              ),
            ),
          ),
          for (final e in feed.events)
            ListTile(
              dense: true,
              leading: Icon(
                e.kind == GeofenceKind.enter ? Icons.login : Icons.logout,
                size: 18,
                color: e.kind == GeofenceKind.enter
                    ? AulColors.primary
                    : AulColors.textSecondary,
              ),
              title: Text(
                e.kind == GeofenceKind.enter
                    ? l10n.geofenceEventEnter(e.label, e.placeName)
                    : l10n.geofenceEventExit(e.label, e.placeName),
                style: const TextStyle(fontSize: 13),
              ),
              trailing: Text(
                materialL10n.formatTimeOfDay(TimeOfDay.fromDateTime(e.at)),
                style: const TextStyle(
                  fontSize: 12,
                  color: AulColors.textSecondary,
                ),
              ),
            ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }
}

/// Formats an ETA in seconds as a compact "<1 min" / "N min" / "N h M min"
/// label. Mirrors the web `fmtEta` in `GeofenceFeed.tsx` exactly: minutes are
/// rounded (`Math.round`), under a minute reads "<1 min", and an hour or more
/// splits into hours + remaining minutes.
String _formatEta(AppLocalizations l10n, double seconds) {
  final m = (seconds / 60).round();
  if (m < 1) return l10n.geofenceEtaLessMin;
  if (m < 60) return l10n.geofenceEtaMin(m);
  final h = m ~/ 60;
  final rem = m % 60;
  return rem != 0 ? l10n.geofenceEtaHourMin(h, rem) : l10n.geofenceEtaHour(h);
}

/// The add/edit place editor floated at the bottom of the map: a name field, a
/// "tap the map" hint, a metre radius slider, and Save / Cancel (+ Delete when
/// editing). All state lives in [_MapScreenState]; this is a thin view.
class _PlaceEditor extends StatelessWidget {
  const _PlaceEditor({
    required this.nameController,
    required this.hasCentre,
    required this.radius,
    required this.isEdit,
    required this.busy,
    required this.onNameChanged,
    required this.onRadiusChanged,
    required this.onSave,
    required this.onCancel,
    required this.onDelete,
  });

  final TextEditingController nameController;
  final bool hasCentre;
  final double radius;
  final bool isEdit;
  final bool busy;
  final VoidCallback onNameChanged;
  final ValueChanged<double> onRadiusChanged;
  final VoidCallback onSave;
  final VoidCallback? onCancel;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canSave = hasCentre && nameController.text.trim().isNotEmpty && !busy;
    return Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              maxLength: 80,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: l10n.placesNameHint,
                counterText: '',
                isDense: true,
              ),
              onChanged: (_) => onNameChanged(),
            ),
            const SizedBox(height: 4),
            Text(
              hasCentre ? l10n.placesCentreSet : l10n.placesTapMap,
              style: const TextStyle(
                color: AulColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${l10n.placesRadiusLabel}: ',
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  l10n.placesRadiusValue(radius.round()),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              min: _kRadiusMin,
              max: _kRadiusMax,
              divisions: ((_kRadiusMax - _kRadiusMin) / 10).round(),
              value: radius.clamp(_kRadiusMin, _kRadiusMax).toDouble(),
              label: l10n.placesRadiusValue(radius.round()),
              onChanged: busy ? null : onRadiusChanged,
            ),
            Row(
              children: [
                if (isEdit)
                  TextButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: AulColors.danger,
                    ),
                    label: Text(
                      l10n.delete,
                      style: const TextStyle(color: AulColors.danger),
                    ),
                  ),
                const Spacer(),
                TextButton(onPressed: onCancel, child: Text(l10n.cancel)),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: canSave ? onSave : null,
                  child: Text(
                    isEdit ? l10n.placesSaveChanges : l10n.placesAddPlace,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A rounded "no one to show yet" pill floated over the basemap.
class _EmptyPill extends StatelessWidget {
  const _EmptyPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AulColors.text.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}

/// A round, white map control floated over the basemap — the house style for an
/// on-map action, distinct from the app-bar [IconButton]s (which can't float
/// over the map) and the danger-red SOS FAB (reserved for SOS). [onPressed] null
/// renders it disabled: greyed and non-interactive, used for "recenter on me"
/// before this account has a fix to fly to. Kept tiny so it is easy to reuse.
class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;

  /// Doubles as the tooltip message and the accessibility label — the icon
  /// carries the meaning visually, so both point at the same one string.
  final String tooltip;

  /// Null disables the button (greyed, no ripple, no callback).
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: AulColors.surface,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: Colors.black26,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                icon,
                size: 22,
                color: enabled ? AulColors.text : AulColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- GeoJSON helpers (mirror the web MapView geoCircleRing / placesToCircles) ---

Map<String, dynamic> _emptyFc() => <String, dynamic>{
  'type': 'FeatureCollection',
  'features': <dynamic>[],
};

/// A geographic circle (radius in metres) as a closed GeoJSON ring, so geofence
/// radii render as true ground distance rather than fixed pixels. Byte-for-byte
/// the same maths as the web `geoCircleRing`.
List<List<double>> _geoCircleRing(
  double lng,
  double lat,
  double radiusM, [
  int steps = 64,
]) {
  const rEarth = 6371000.0;
  final dLat = (radiusM / rEarth) * (180 / math.pi);
  final dLng = dLat / math.cos(lat * math.pi / 180);
  final ring = <List<double>>[];
  for (var i = 0; i <= steps; i++) {
    final t = (i / steps) * 2 * math.pi;
    ring.add([lng + dLng * math.cos(t), lat + dLat * math.sin(t)]);
  }
  return ring;
}

Map<String, dynamic> _circleFc(double lng, double lat, double radiusM) =>
    <String, dynamic>{
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': <String, dynamic>{},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [_geoCircleRing(lng, lat, radiusM)],
          },
        },
      ],
    };

/// The accuracy halo for each member whose fix carries a useful radius, as true
/// ground-distance rings (same maths as the geofence circles).
///
/// A fix is a claim with an error bar, and the marker alone renders a ±500 m
/// network guess with exactly the same confidence as a ±5 m GPS lock. The halo
/// puts the error bar back on the map: "she is somewhere in here", not "she is
/// on this doorstep". City-mode members coarsen their own accuracy to >=1 km
/// before sealing, so their halo shows the grid they actually shared — the
/// circle sees the vagueness that was intended, not a false point.
///
/// Skipped when [MemberPosition.fix]'s accuracy is absent (an older reporter, or
/// a platform that won't say) or below [_kAccuracyMinMeters]: at that point the
/// ring is smaller than the pin it would sit under, so it says nothing and only
/// adds clutter.
Map<String, dynamic> positionsToAccuracyCircles(
  Iterable<MemberPosition> positions,
) => <String, dynamic>{
  'type': 'FeatureCollection',
  'features': [
    for (final p in positions)
      if ((p.fix.accuracy ?? 0) >= _kAccuracyMinMeters)
        {
          'type': 'Feature',
          'properties': {'id': p.deviceId},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              _geoCircleRing(p.fix.lng, p.fix.lat, p.fix.accuracy!),
            ],
          },
        },
  ],
};

Map<String, dynamic> _placesToCircles(List<Place> places) => <String, dynamic>{
  'type': 'FeatureCollection',
  'features': [
    for (final p in places)
      {
        'type': 'Feature',
        'properties': {'id': p.id, 'name': p.name},
        'geometry': {
          'type': 'Polygon',
          'coordinates': [_geoCircleRing(p.lng, p.lat, p.radius)],
        },
      },
  ],
};

/// Place labels: the decrypted name, plus the owner line [ownerLabelOf] resolves
/// from `created_by` ('' when unknown, which renders nothing).
Map<String, dynamic> _placesToLabels(
  List<Place> places,
  String? Function(Place) ownerLabelOf,
) => <String, dynamic>{
  'type': 'FeatureCollection',
  'features': [
    for (final p in places)
      {
        'type': 'Feature',
        'properties': {
          'id': p.id,
          'name': p.name,
          'owner': ownerLabelOf(p) ?? '',
        },
        'geometry': {
          'type': 'Point',
          'coordinates': [p.lng, p.lat],
        },
      },
  ],
};

/// Luminance (Rec. 709) matrix — collapses RGB to grey, alpha untouched. The
/// canvas equivalent of the web marker's `filter: grayscale(1)`.
const ColorFilter _kGreyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// The Google-Maps-style slide-up roster over the live map: a draggable bottom
/// sheet listing the circle members who have a position, tap a row to fly the
/// camera to them. Mirrors the web dashboard's mobile `MobileSheet` wrapping the
/// members panel. Data comes straight from the map's live positions, so it stays
/// in step with the markers without a second fetch.
class _MemberListSheet extends StatelessWidget {
  const _MemberListSheet({
    required this.controller,
    required this.members,
    required this.myUserId,
    required this.onTapMember,
  });

  final DraggableScrollableController controller;
  final List<MemberPosition> members;
  final String? myUserId;
  final void Function(MemberPosition) onTapMember;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      controller: controller,
      initialChildSize: _kSheetPeek,
      minChildSize: _kSheetPeek,
      maxChildSize: _kSheetFull,
      snap: true,
      snapSizes: const [_kSheetPeek, _kSheetHalf, _kSheetFull],
      builder: (context, scrollController) => DecoratedBox(
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 24,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        // One scroll view so the whole sheet — handle and header included — is
        // draggable, not just the list rows.
        child: ListView(
          controller: scrollController,
          padding: EdgeInsets.zero,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                  color: AulColors.textSecondary.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '${l10n.membersTitle} · ${members.length}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Divider(height: 1),
            if (members.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                child: Text(
                  l10n.mapEmpty,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AulColors.textSecondary),
                ),
              )
            else
              for (final m in members)
                _MemberSheetRow(
                  pos: m,
                  isMe: m.userId != null && m.userId == myUserId,
                  onTap: () => onTapMember(m),
                ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// One row in the slide-up sheet: avatar, name (+ "you"), and a compact status
/// line (paused/stale · phone/PC · battery · updated N ago). Tapping it flies the
/// map to that member and collapses the sheet.
class _MemberSheetRow extends StatelessWidget {
  const _MemberSheetRow({
    required this.pos,
    required this.isMe,
    required this.onTap,
  });

  final MemberPosition pos;
  final bool isMe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final stale = isStale(pos.fix.capturedAt, now);
    final facts = <String>[
      if (pos.isPaused) l10n.precisionPaused,
      if (stale) l10n.staleBadge,
      pos.isPc ? l10n.mapTagPc : l10n.mapTagPhone,
      if (pos.battery != null) l10n.batteryPercent(pos.battery!),
      formatAgo(l10n, pos.updatedAt, now),
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      leading: _SheetAvatar(pos: pos),
      title: Row(
        children: [
          Flexible(
            child: Text(
              pos.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 6),
            Text(
              l10n.profileYou,
              style: const TextStyle(
                fontSize: 12,
                color: AulColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        facts,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: stale ? AulColors.amber : AulColors.textSecondary,
        ),
      ),
      trailing: const Icon(
        Icons.my_location,
        size: 18,
        color: AulColors.textSecondary,
      ),
    );
  }
}

/// The member's avatar for a sheet row: their decoded picture, or a coloured
/// circle with their initial (same fallback the map marker uses).
class _SheetAvatar extends StatelessWidget {
  const _SheetAvatar({required this.pos});

  final MemberPosition pos;

  @override
  Widget build(BuildContext context) {
    final bytes = pos.avatarBytes;
    if (bytes != null) {
      return CircleAvatar(radius: 20, backgroundImage: MemoryImage(bytes));
    }
    return CircleAvatar(
      radius: 20,
      backgroundColor: AulColors.primary,
      child: Text(
        pos.initial,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Renders a circular marker image on-device: the member's [avatar] clipped to a
/// circle when present, else a filled pin with the member's [initial]. When
/// [paused] the artwork is desaturated (grey avatar / grey pin) so the marker
/// reads as "sharing off" at a glance rather than as a live position. Returned
/// as PNG bytes for `MapLibreMapController.addImage`. Runs only on a live engine
/// (the map screen), so it is never exercised by the pipeline unit tests.
Future<Uint8List> _renderMarker({
  Uint8List? avatar,
  required String initial,
  bool paused = false,
  bool sos = false,
}) async {
  const size = 128.0;
  const border = 6.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final center = const Offset(size / 2, size / 2);
  final radius = size / 2 - border;

  // White outer ring so the marker reads on any basemap — RED while this member
  // is raising an SOS, so a person in distress is unmistakable for everyone
  // watching. The inner avatar/pin is left untouched (matching the web, whose
  // `.aul-marker--sos` reddens the ring, not the face), and the animated red
  // halo pulses under it (see `_tickSosPulse`).
  canvas.drawCircle(
    center,
    radius + border / 2,
    Paint()..color = sos ? AulColors.danger : Colors.white,
  );

  ui.Image? decoded;
  if (avatar != null) {
    try {
      final codec = await ui.instantiateImageCodec(
        avatar,
        targetWidth: size.toInt(),
        targetHeight: size.toInt(),
      );
      decoded = (await codec.getNextFrame()).image;
    } catch (_) {
      decoded = null;
    }
  }

  if (decoded != null) {
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawImageRect(
      decoded,
      Rect.fromLTWH(0, 0, decoded.width.toDouble(), decoded.height.toDouble()),
      Rect.fromCircle(center: center, radius: radius),
      Paint()..colorFilter = paused ? _kGreyscale : null,
    );
    canvas.restore();
  } else {
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = paused ? AulColors.textSecondary : AulColors.primary,
    );
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textAlign: TextAlign.center,
              fontSize: radius,
              fontWeight: FontWeight.w700,
            ),
          )
          ..pushStyle(ui.TextStyle(color: Colors.white))
          ..addText(initial);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: size));
    canvas.drawParagraph(
      paragraph,
      Offset(0, center.dy - paragraph.height / 2),
    );
  }

  final image = await recorder.endRecording().toImage(
    size.toInt(),
    size.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
