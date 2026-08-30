import 'package:flutter_tts/flutter_tts.dart';
import 'lane_logic.dart';

/// Speaks lane-status alerts out loud, with a per-status cooldown so it
/// doesn't repeat the same warning every single frame (mirrors the
/// Python VoiceAlert class, tested in test_deep.py TEST 21/22).
class TtsAlertService {
  final FlutterTts _tts = FlutterTts();
  final double cooldownS;
  final Map<LaneStatus, DateTime> _lastSpoken = {};
  bool enabled;

  TtsAlertService({this.cooldownS = 4.0, this.enabled = true}) {
    _tts.setSpeechRate(0.5);
    _tts.setVolume(1.0);
    _tts.setLanguage('en-US');
  }

  Future<void> maybeSay(LaneStatus status) async {
    if (!enabled) return;
    final phrase = laneStatusSpeech(status);
    if (phrase == null) return;

    final now = DateTime.now();
    final last = _lastSpoken[status];
    if (last != null && now.difference(last).inMilliseconds < cooldownS * 1000) {
      return; // still in cooldown for this specific status
    }
    _lastSpoken[status] = now;
    await _tts.speak(phrase);
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
