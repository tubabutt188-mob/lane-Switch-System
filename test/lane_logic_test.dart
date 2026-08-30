// Run with: flutter test
// Mirrors test_logic.py + test_deep.py from the Python version.
import 'package:flutter_test/flutter_test.dart';
import 'package:lane_switch_system/lane_logic.dart';

void main() {
  test('stoppingDistanceM increases with speed', () {
    expect(stoppingDistanceM(60) < stoppingDistanceM(120), true);
  });

  test('decide() REAR mode: urgent + adjacent clear -> CHANGE LANE NOW', () {
    final s = decide(
      egoSpeedKmh: 100,
      closingKmh: 40,
      distanceM: 8,
      adjacentLaneClear: true,
      cameraMode: CameraMode.rear,
    );
    expect(s, LaneStatus.changeLaneNow);
  });

  test('decide() REAR mode: urgent + adjacent blocked -> HOLD', () {
    final s = decide(
      egoSpeedKmh: 100,
      closingKmh: 40,
      distanceM: 8,
      adjacentLaneClear: false,
      cameraMode: CameraMode.rear,
    );
    expect(s, LaneStatus.holdDoNotLaneChange);
  });

  test(
      'decide() REAR mode moderate risk -> WATCH (regression test for the '
      'safe-gap bug: must NOT jump straight to CHANGE LANE NOW)', () {
    final s = decide(
      egoSpeedKmh: 100,
      closingKmh: 30,
      distanceM: 45,
      adjacentLaneClear: true,
      cameraMode: CameraMode.rear,
    );
    expect(s, LaneStatus.watchClosingFast);
  });

  test('decide() closing speed exactly 5 km/h -> CLEAR', () {
    final s = decide(
      egoSpeedKmh: 100,
      closingKmh: 5,
      distanceM: 10,
      adjacentLaneClear: true,
      cameraMode: CameraMode.rear,
    );
    expect(s, LaneStatus.clear);
  });

  test('decide() FRONT mode -> OVERTAKE NOW', () {
    final s = decide(
      egoSpeedKmh: 100,
      closingKmh: 25,
      distanceM: 10,
      adjacentLaneClear: true,
      cameraMode: CameraMode.front,
    );
    expect(s, LaneStatus.overtakeNow);
  });

  test('estimateDistanceM handles zero width without crashing', () {
    expect(estimateDistanceM(0), double.infinity);
  });

  test('RearVehicleTrack: closing speed from shrinking distance', () {
    final track = RearVehicleTrack();
    track.update(0.0, 50.0);
    track.update(1.0, 40.0); // 10m closed in 1s = 36 km/h
    final speed = track.closingSpeedKmh();
    expect(speed, closeTo(36.0, 2.0));
  });

  test('RearVehicleTrack respects historyLen cap', () {
    final track = RearVehicleTrack();
    for (var i = 0; i < 20; i++) {
      track.update(i.toDouble(), (50 - i).toDouble());
    }
    expect(track.length, historyLen);
  });

  test('Detection filters out low-confidence boxes', () {
    final weak = Detection(
      className: 'car',
      confidence: 0.20, // below detectionConfThreshold
      x: 0.8,
      y: 0.4,
      width: 0.1,
      height: 0.1,
      pixelWidthPx:
          100, // arbitrary for these lane-side tests (distance not checked here)
    );
    expect(weak.isReliableVehicle(), false);
  });

  test('Detection filters out tiny/noisy boxes', () {
    final tiny = Detection(
      className: 'car',
      confidence: 0.9,
      x: 0.9,
      y: 0.5,
      width: 0.01,
      height: 0.01,
      pixelWidthPx:
          100, // arbitrary for these lane-side tests (distance not checked here)
    );
    expect(tiny.isReliableVehicle(), false);
  });

  test('Detection ignores non-vehicle classes', () {
    final person = Detection(
      className: 'person',
      confidence: 0.95,
      x: 0.85,
      y: 0.4,
      width: 0.1,
      height: 0.3,
      pixelWidthPx:
          100, // arbitrary for these lane-side tests (distance not checked here)
    );
    expect(person.isReliableVehicle(), false);
  });

  test(
      'isAdjacentLaneClearRaw: RIGHT side (Pakistan) — car on the right '
      'blocks the adjacent lane', () {
    final boundaryX = 1 - adjacentLaneFraction; // ~0.65
    final carOnRight = Detection(
      className: 'car',
      confidence: 0.9,
      x: 0.85,
      y: 0.4,
      width: 0.12,
      height: 0.2,
      pixelWidthPx:
          100, // arbitrary for these lane-side tests (distance not checked here)
    );
    final clear = isAdjacentLaneClearRaw([carOnRight], boundaryX);
    expect(clear, false);
  });

  test(
      'isAdjacentLaneClearRaw: RIGHT side — car on the left does NOT '
      'block the (right) adjacent lane', () {
    final boundaryX = 1 - adjacentLaneFraction;
    final carOnLeft = Detection(
      className: 'car',
      confidence: 0.9,
      x: 0.1,
      y: 0.4,
      width: 0.15,
      height: 0.25,
      pixelWidthPx:
          100, // arbitrary for these lane-side tests (distance not checked here)
    );
    final clear = isAdjacentLaneClearRaw([carOnLeft], boundaryX);
    expect(clear, true);
  });

  test('AdjacentLaneVote debounces a single noisy frame', () {
    final vote = AdjacentLaneVote(window: 5);
    final seq = [true, true, true, false, true];
    late bool result;
    for (final v in seq) {
      result = vote.update(v);
    }
    expect(result, true); // majority still clear
  });

  test('AdjacentLaneVote reflects sustained blockage', () {
    final vote = AdjacentLaneVote(window: 5);
    final seq = [true, true, false, false, false];
    late bool result;
    for (final v in seq) {
      result = vote.update(v);
    }
    expect(result, false); // majority now blocked
  });
}
