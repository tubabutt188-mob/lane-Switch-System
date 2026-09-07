import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'lane_logic.dart';
import 'tts_service.dart';

/// IMPORTANT — verify against the installed `ultralytics_yolo` version:
/// This file is written against the plugin's public docs (YOLOView widget,
/// onResult callback returning a list of results with className/confidence/
/// boundingBox). Package APIs evolve — if `flutter pub get` / `flutter run`
/// shows a mismatch (e.g. field renamed), check:
///   https://pub.dev/documentation/ultralytics_yolo/latest/
/// and adjust the few lines marked "PLUGIN API" below. Everything in
/// lane_logic.dart (the tested decision logic) does not need to change.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final RearVehicleTrack _track = RearVehicleTrack();
  final AdjacentLaneVote _laneVote = AdjacentLaneVote();
  final TtsAlertService _tts = TtsAlertService(cooldownS: 4.0);

  // --- Runtime config (surface these as Settings UI later if you want) ---
  final CameraMode _cameraMode = CameraMode.rear; // REAR = "CHANGE LANE NOW"
  final double _egoSpeedKmh = 100;

  LaneStatus _status = LaneStatus.clear;
  double? _distanceM;
  double _closingKmh = 0;
  bool _adjacentClear = true;

  // Camera permission must be requested at RUNTIME (Android 6+/iOS) —
  // declaring it in AndroidManifest.xml/Info.plist alone is not enough.
  bool _permissionGranted = false;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _permissionGranted = status.isGranted;
      _permissionDenied = !status.isGranted;
    });
  }

  @override
  void dispose() {
    _tts.dispose();
    super.dispose();
  }

  void _onDetections(List<Detection> detections) {
    // boundaryX in the SAME normalized (0..1) space as Detection.x/width.
    const double boundaryX = adjacentLaneSide == LaneSide.right
        ? 1 - adjacentLaneFraction
        : adjacentLaneFraction;

    final rawClear = isAdjacentLaneClearRaw(detections, boundaryX);
    final adjacentClear = _laneVote.update(rawClear);
    final box = pickClosestOwnLaneVehicle(detections, boundaryX);

    LaneStatus status = LaneStatus.clear;
    double? distanceM;
    double closingKmh = 0;

    if (box != null) {
      // Use the plugin's REAL pixel bounding-box width directly — no need
      // to approximate frame width from the screen size.
      distanceM = estimateDistanceM(box.pixelWidthPx);
      _track.update(DateTime.now().millisecondsSinceEpoch / 1000.0, distanceM);
      closingKmh = _track.closingSpeedKmh();
      status = decide(
        egoSpeedKmh: _egoSpeedKmh,
        closingKmh: closingKmh,
        distanceM: distanceM,
        adjacentLaneClear: adjacentClear,
        cameraMode: _cameraMode,
      );
    }

    setState(() {
      _status = status;
      _distanceM = distanceM;
      _closingKmh = closingKmh;
      _adjacentClear = adjacentClear;
    });

    _tts.maybeSay(status);
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.videocam_off, color: Colors.white54, size: 48),
                SizedBox(height: 16),
                Text(
                  'Camera permission is required for this app to work.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: openAppSettings,
                  child: Text('Open Settings'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_permissionGranted) {
      // Still waiting on the permission dialog / request to resolve.
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ---------- Camera + YOLO detection view ----------
          // Verified against ultralytics_yolo 0.6.14's YOLOResult class
          // (confirmed via pub.dev docs): className, confidence,
          // boundingBox (Rect, pixel coords), normalizedBox (Rect, 0..1).
          // Use an official model id to start quickly, e.g. 'yolo11n', OR
          // point modelPath at your own exported yolo11n.tflite placed in
          // assets/models/ (see pubspec.yaml + README for export steps).
          YOLOView(
            modelPath: 'assets/model/yolo26n.tflite',
            task: YOLOTask.detect,
            onResult: (results) {
              final detections = results.map((r) {
                return Detection(
                  className: r.className,
                  confidence: r.confidence,
                  x: r.normalizedBox.left,
                  y: r.normalizedBox.top,
                  width: r.normalizedBox.width,
                  height: r.normalizedBox.height,
                  pixelWidthPx: r.boundingBox.width,
                );
              }).toList();
              _onDetections(detections);
            },
          ),

          // ---------- HUD overlay ----------
          Positioned(
            top: 40,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: _statusColor(_status).withOpacity(0.9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                laneStatusLabel(_status),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
          ),
          if (_distanceM != null)
            Positioned(
              top: 100,
              left: 16,
              child: Container(
                padding: const EdgeInsets.all(10),
                color: Colors.black54,
                child: Text(
                  'Distance: ${_distanceM!.toStringAsFixed(1)} m\n'
                  'Closing:  ${_closingKmh.toStringAsFixed(0)} km/h\n'
                  'Adjacent lane: ${_adjacentClear ? "CLEAR" : "BLOCKED"}',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Color _statusColor(LaneStatus s) {
    if (laneChangeStatuses.contains(s)) return Colors.green.shade700;
    if (holdStatuses.contains(s)) return Colors.red.shade700;
    if (s == LaneStatus.watchClosingFast ||
        s == LaneStatus.watchClosingOnAhead) {
      return Colors.orange.shade700;
    }
    return Colors.green.shade400; // CLEAR
  }
}
