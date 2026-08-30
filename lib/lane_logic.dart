/// Core decision logic for the Lane Switch System — ported from the
/// Python model AFTER all 3 bugs found during testing were fixed:
///   1. safe_gap now uses CLOSING speed, not (ego + closing) combined speed
///      (previously skipped the WATCH state and jumped straight to urgent)
///   2. (Python-only concern) wall-clock vs video-timeline timing bug —
///      N/A here since a live phone camera genuinely runs in real time, so
///      using the real system clock for closing-speed timing is correct
///      for THIS live use case.
///   3. Adjacent/overtaking lane defaults to the RIGHT side of the frame,
///      matching Pakistan's left-hand traffic (overtake on the right).
library lane_logic;

// ---------------------------------------------------------------------
// CONFIG — tune these for your setup (mirrors the Python CONFIG section)
// ---------------------------------------------------------------------

/// COCO vehicle class names the plugin will report (className is a string
/// here, not a numeric id, since the Flutter plugin resolves class names
/// from the model's metadata for you).
const Set<String> vehicleClasses = {'car', 'motorcycle', 'bus', 'truck'};

const double knownVehicleWidthM = 1.8; // average car width
double focalLengthPx =
    739; // Calibrated: photo of car at 10m, measured 133px width

const int historyLen = 6;

const double reactionTimeS = 1.5;
const double decelMs2 = 7.0;

/// "REAR"  = phone camera faces backward (tracks a vehicle approaching from
///           behind -> avoid getting rear-ended -> change lane out of the way)
/// "FRONT" = phone camera faces forward (overtake-assist -> change lane to pass)
enum CameraMode { rear, front }

/// Pakistan / left-hand-traffic: overtake from the RIGHT.
/// Set to LaneSide.left for right-hand-traffic countries.
enum LaneSide { left, right }

const double adjacentLaneFraction = 0.35;
const LaneSide adjacentLaneSide = LaneSide.right;

const double detectionConfThreshold = 0.45;
const double minBoxAreaFraction = 0.004;
const int adjacentLaneVoteWindow = 5;

/// A single detection. x/y/width/height are in NORMALIZED frame coordinates
/// (0..1), used for lane-side (own/adjacent) comparisons. `pixelWidthPx` is
/// the box's REAL pixel width (from the plugin's boundingBox, not derived by
/// multiplying the normalized width by an approximate screen size) — this is
/// what estimateDistanceM() should be called with, for accuracy.
class Detection {
  final String className;
  final double confidence;
  final double x; // left, 0..1 (normalized)
  final double y; // top, 0..1 (normalized)
  final double width; // 0..1 (normalized)
  final double height; // 0..1 (normalized)
  final double pixelWidthPx; // actual bounding-box width in pixels

  Detection({
    required this.className,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.pixelWidthPx,
  });

  double get centerX => x + width / 2;
  double get areaFraction => width * height;

  bool isReliableVehicle() {
    if (!vehicleClasses.contains(className)) return false;
    if (confidence < detectionConfThreshold) return false;
    if (areaFraction < minBoxAreaFraction) return false;
    return true;
  }
}

/// Reaction distance + braking distance, in meters, for a given speed.
double stoppingDistanceM(double speedKmh) {
  final speedMs = speedKmh / 3.6;
  final reactionDistance = speedMs * reactionTimeS;
  final brakingDistance = (speedMs * speedMs) / (2 * decelMs2);
  return reactionDistance + brakingDistance;
}

/// Monocular distance estimate from a bounding box's PIXEL width.
/// Pass box width in pixels (normalizedWidth * frameWidthPx).
double estimateDistanceM(double bboxWidthPx) {
  if (bboxWidthPx <= 0) return double.infinity;
  return (knownVehicleWidthM * focalLengthPx) / bboxWidthPx;
}

/// Tracks recent (time, distance) samples to derive closing speed.
/// For a LIVE camera feed, real wall-clock time (DateTime.now()) is the
/// correct clock to use — unlike the Python file-processing case, there's
/// no mismatch between "processing speed" and "real time" here.
class RearVehicleTrack {
  final List<MapEntry<double, double>> _history = [];

  void update(double tSeconds, double distanceM) {
    _history.add(MapEntry(tSeconds, distanceM));
    if (_history.length > historyLen) {
      _history.removeAt(0);
    }
  }

  double closingSpeedKmh() {
    if (_history.length < 2) return 0.0;

    // Average the first 2 and last 2 samples (instead of comparing only the
    // single first/last readings) so a one-frame detection-noise jitter in
    // the bounding-box width can't, by itself, look like a real closing
    // motion for a vehicle that (and the phone) is actually stationary.
    final useAvg = _history.length >= 4;
    final firstVal = useAvg
        ? (_history[0].value + _history[1].value) / 2
        : _history.first.value;
    final lastVal = useAvg
        ? (_history[_history.length - 2].value +
                _history[_history.length - 1].value) /
            2
        : _history.last.value;

    final dt = _history.last.key - _history.first.key;
    if (dt <= 0) return 0.0;
    final closingMs = (firstVal - lastVal) / dt; // positive = approaching
    final kmh = closingMs * 3.6;
    return kmh > 0 ? kmh : 0.0;
  }

  int get length => _history.length;
}

/// All possible advisory statuses.
enum LaneStatus {
  clear,
  watchClosingFast, // REAR mode
  watchClosingOnAhead, // FRONT mode
  changeLaneNow, // REAR mode, adjacent clear
  holdDoNotLaneChange, // REAR mode, adjacent blocked
  overtakeNow, // FRONT mode, adjacent clear
  holdSlowDown, // FRONT mode, adjacent blocked
}

const Set<LaneStatus> laneChangeStatuses = {
  LaneStatus.changeLaneNow,
  LaneStatus.overtakeNow,
};
const Set<LaneStatus> holdStatuses = {
  LaneStatus.holdDoNotLaneChange,
  LaneStatus.holdSlowDown,
};

/// The core decision function — BUG-FIXED VERSION.
///
/// REAR mode: a vehicle behind is catching up to YOU. The safe gap is based
///   on the CLOSING RATE (relative speed) needed to neutralize the gap —
///   NOT the following vehicle's full ground speed (that was the bug: using
///   ego+closing produced huge, unrealistic safe-gap distances that made
///   ordinary situations look urgent and skipped the WATCH state).
/// FRONT mode: YOU are catching up to a slower vehicle ahead. The safe gap
///   is based on YOUR OWN braking distance at your own speed.
LaneStatus decide({
  required double egoSpeedKmh,
  required double closingKmh,
  required double distanceM,
  required bool adjacentLaneClear,
  required CameraMode cameraMode,
}) {
  if (closingKmh <= 5) return LaneStatus.clear;

  final double safeGap = cameraMode == CameraMode.rear
      ? stoppingDistanceM(closingKmh)
      : stoppingDistanceM(egoSpeedKmh);

  final double ttc =
      closingKmh > 0 ? distanceM / (closingKmh / 3.6) : double.infinity;

  if (distanceM <= safeGap || ttc <= 5) {
    if (cameraMode == CameraMode.rear) {
      return adjacentLaneClear
          ? LaneStatus.changeLaneNow
          : LaneStatus.holdDoNotLaneChange;
    } else {
      return adjacentLaneClear
          ? LaneStatus.overtakeNow
          : LaneStatus.holdSlowDown;
    }
  }
  if (ttc <= 9) {
    return cameraMode == CameraMode.rear
        ? LaneStatus.watchClosingFast
        : LaneStatus.watchClosingOnAhead;
  }
  return LaneStatus.clear;
}

/// Human-readable label (for on-screen display).
String laneStatusLabel(LaneStatus s) {
  switch (s) {
    case LaneStatus.clear:
      return 'CLEAR';
    case LaneStatus.watchClosingFast:
      return 'WATCH — VEHICLE CLOSING FAST';
    case LaneStatus.watchClosingOnAhead:
      return 'WATCH — CLOSING ON VEHICLE AHEAD';
    case LaneStatus.changeLaneNow:
      return 'CHANGE LANE NOW';
    case LaneStatus.holdDoNotLaneChange:
      return 'HOLD — DO NOT LANE CHANGE';
    case LaneStatus.overtakeNow:
      return 'OVERTAKE NOW';
    case LaneStatus.holdSlowDown:
      return 'HOLD — SLOW DOWN, DO NOT OVERTAKE';
  }
}

/// Spoken phrase for each status (null = don't speak, e.g. CLEAR).
String? laneStatusSpeech(LaneStatus s) {
  switch (s) {
    case LaneStatus.changeLaneNow:
      return 'Warning. Change lane now.';
    case LaneStatus.holdDoNotLaneChange:
      return 'Warning. Brake. Do not change lane.';
    case LaneStatus.watchClosingFast:
      return 'Vehicle closing fast behind you.';
    case LaneStatus.overtakeNow:
      return 'Vehicle ahead is slow. Overtake now.';
    case LaneStatus.holdSlowDown:
      return 'Slow down. Do not overtake.';
    case LaneStatus.watchClosingOnAhead:
      return 'Closing in on vehicle ahead.';
    case LaneStatus.clear:
      return null;
  }
}

/// Given all reliable detections in this frame and where the own/adjacent
/// lane boundary sits (0..1, normalized), pick the closest vehicle in OWN
/// lane and report whether it's in view.
Detection? pickClosestOwnLaneVehicle(
    List<Detection> detections, double boundaryX) {
  Detection? best;
  double bestArea = 0;
  for (final d in detections) {
    if (!d.isReliableVehicle()) continue;
    final inOwnLane = adjacentLaneSide == LaneSide.right
        ? d.centerX <= boundaryX
        : d.centerX >= boundaryX;
    if (!inOwnLane) continue;
    final area = d.areaFraction;
    if (area > bestArea) {
      bestArea = area;
      best = d;
    }
  }
  return best;
}

/// Raw (un-debounced) adjacent-lane clear check for this single frame.
bool isAdjacentLaneClearRaw(List<Detection> detections, double boundaryX) {
  for (final d in detections) {
    if (!d.isReliableVehicle()) continue;
    final inAdjacentLane = adjacentLaneSide == LaneSide.right
        ? d.centerX > boundaryX
        : d.centerX < boundaryX;
    if (inAdjacentLane) return false;
  }
  return true;
}

/// Majority-vote debounce over the last N frames, so one noisy frame can't
/// flip CLEAR/BLOCKED and cause a spurious spoken alert.
class AdjacentLaneVote {
  final int window;
  final List<bool> _recent = [];

  AdjacentLaneVote({this.window = adjacentLaneVoteWindow});

  bool update(bool rawClear) {
    _recent.add(rawClear);
    if (_recent.length > window) {
      _recent.removeAt(0);
    }
    final clearVotes = _recent.where((v) => v).length;
    return clearVotes * 2 >= _recent.length; // majority = clear
  }
}
