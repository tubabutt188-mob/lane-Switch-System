import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Shows the phone's current speed (as a proxy for the vehicle's speed),
/// read live from GPS. This is a separate, simpler mode from the Lane
/// Switch System camera screen -- no camera, no YOLO, just a speedometer.
class SpeedScreen extends StatefulWidget {
  const SpeedScreen({super.key});

  @override
  State<SpeedScreen> createState() => _SpeedScreenState();
}

class _SpeedScreenState extends State<SpeedScreen> {
  StreamSubscription<Position>? _positionStream;
  double _speedKmh = 0.0;
  String _statusMessage = 'Waiting for GPS signal...';
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _startListening();
  }

  Future<void> _startListening() async {
    // GPS (device location service) must be turned on.
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _statusMessage = 'Please turn on Location (GPS) in your phone settings.';
      });
      return;
    }

    // Location permission must be granted at runtime (Android 6+/iOS).
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _permissionDenied = true;
          _statusMessage = 'Location permission is required to show speed.';
        });
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _permissionDenied = true;
        _statusMessage =
            'Location permission is permanently denied. Enable it from Settings.';
      });
      return;
    }

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0, // report every update, not just after moving X meters
    );

    _positionStream =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        // position.speed is in meters/second; GPS can report tiny negative
        // noise when stationary, so clamp to zero.
        final speedMs = position.speed < 0 ? 0.0 : position.speed;
        setState(() {
          _speedKmh = speedMs * 3.6;
          _statusMessage = '';
        });
      },
      onError: (_) {
        setState(() {
          _statusMessage = 'Could not read GPS. Make sure Location is on.';
        });
      },
    );
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Speed Check'),
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: Center(
        child: _statusMessage.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.gps_off, color: Colors.white54, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    if (_permissionDenied) ...[
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: Geolocator.openAppSettings,
                        child: const Text('Open Settings'),
                      ),
                    ],
                  ],
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _speedKmh.toStringAsFixed(0),
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 96,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'km/h',
                    style: TextStyle(color: Colors.white70, fontSize: 24),
                  ),
                ],
              ),
      ),
    );
  }
}
