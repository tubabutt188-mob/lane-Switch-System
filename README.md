# Lane Switch System — Flutter App

Ported from the tested Python model. All 3 bugs found during testing
(safe-gap formula, timing, left/right lane confusion) are already fixed
in `lib/lane_logic.dart`.

## ⚠️ Important — what I could and couldn't verify

I wrote this code in a sandbox with **no Flutter/Dart SDK available** — I
could not run `flutter pub get`, `flutter analyze`, `flutter test`, or
`flutter run` here. Unlike the Python version (tested 27 ways in this
chat), this Flutter code has **not been executed**. Please run the steps
below yourself before trusting it in a car.

## Setup

1. Install Flutter SDK (flutter.dev) if you haven't already.
2. In this project folder:
   ```
   flutter pub get
   flutter test          # runs test/lane_logic_test.dart — do this FIRST
   ```
3. Connect an Android phone (USB debugging on) or open an emulator:
   ```
   flutter run
   ```

## Fixed since first version

- `pubspec.yaml` had a literal placeholder `^latest_version` instead of a
  real version — fixed to `^0.6.14` (the actual current release, verified
  against pub.dev).
- `camera_screen.dart` and `lane_logic.dart` now use the CONFIRMED
  `ultralytics_yolo` 0.6.14 `YOLOResult` API (checked against the official
  Dart API docs): `className`, `confidence`, `boundingBox` (Rect, pixel
  coords), `normalizedBox` (Rect, 0..1). Distance estimation now uses the
  real pixel bounding-box width directly instead of approximating it from
  screen size.

## Model setup (two options)

**Option A — quick start:** `camera_screen.dart` currently points
`modelPath: 'yolo11n'` at an official Ultralytics model ID — the plugin
resolves and downloads it for you.

**Option B — use your own already-tuned model:** export your existing
`yolo11n.pt` to TFLite:
```
pip install ultralytics
yolo export model=yolo11n.pt format=tflite
```
Drop the resulting `.tflite` (and any `.yaml`/metadata file it produces)
into `assets/models/`, then update `modelPath` in `camera_screen.dart` to
point at that asset path instead.

## Before real use — calibrate `focalLengthPx`

In `lib/lane_logic.dart`:
```dart
double focalLengthPx = 700; // MUST calibrate per-phone/camera
```
Same calibration procedure as the Python version:
1. Park a car of known width (1.8m) at a known distance D from the phone.
2. Run the app, note the bounding box's pixel width W for that car.
3. `focalLengthPx = (W * D) / 1.8`

Without this, distance/closing-speed numbers will be in the right
ballpark but not accurate for your specific phone's camera.

## Verify the plugin API matches this code

`ultralytics_yolo` is actively developed — field names on the result
object (`className`, `confidence`, `boundingBox`) may have shifted by the
time you install it. If `flutter pub get`/`flutter run` shows errors in
`camera_screen.dart`, check the current API at
https://pub.dev/documentation/ultralytics_yolo/latest/ and adjust just
the `onResult` callback — `lib/lane_logic.dart` (the actual decision
logic) doesn't need to change.

## Configuration

All in `lib/lane_logic.dart`:
- `adjacentLaneSide` — `LaneSide.right` (Pakistan default, overtake on
  the right). Set to `LaneSide.left` for right-hand-traffic countries.
- `CameraMode` — set in `camera_screen.dart`'s `_cameraMode` field.
  `.rear` = "CHANGE LANE NOW" wording, `.front` = "OVERTAKE NOW" wording.
- `_egoSpeedKmh` in `camera_screen.dart` is currently a fixed placeholder
  (100) — wire it up to a GPS speed plugin (e.g. `geolocator`) for real use.

## Known limitations to test yourself

- Live wall-clock timing for closing-speed calc is correct for a live
  camera (unlike the Python file-processing bug) — but hasn't been
  verified against real detection latency on an actual phone.
- `frameWidthPx` currently falls back to screen width as an approximation
  — replace with the actual camera frame resolution if the plugin exposes
  it, for more accurate distance estimates.
