import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/voice_recording_clock.dart';

void main() {
  test('a recording without native progress does not stay at 0:00', () {
    final clock = VoiceRecordingClock();
    for (var i = 0; i < 30; i++) {
      clock.tick(const Duration(milliseconds: 100), paused: false);
      clock.update(Duration.zero);
    }
    expect(clock.seconds, 3);
    expect(clock.hasRecorderProgress, isFalse);
  });

  test('fallback time excludes pauses and yields to native progress', () {
    final clock = VoiceRecordingClock();
    clock.tick(const Duration(seconds: 1), paused: false);
    clock.tick(const Duration(seconds: 2), paused: true);
    expect(clock.seconds, 1);
    clock.update(const Duration(milliseconds: 1200));
    clock.tick(const Duration(seconds: 2), paused: false);
    expect(clock.seconds, 1.2);
    expect(clock.hasRecorderProgress, isTrue);
    clock.update(const Duration(seconds: 3));
    expect(clock.seconds, 3);
  });
}
