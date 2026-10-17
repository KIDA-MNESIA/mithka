import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/music_player_controller.dart';
import 'package:mithka/chat/voice_audio.dart';
import 'package:mithka/tdlib/td_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ChatMessage track(int fileId) => ChatMessage(
    id: fileId,
    isOutgoing: false,
    text: '',
    date: 1,
    chatId: 9,
    music: MessageMusic(
      title: 'Track $fileId',
      performer: 'Artist',
      duration: 60,
      file: TdFileRef(id: fileId),
    ),
  );

  /// Lets the recovery attempt a failure schedules run before asserting.
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'a track that fails every attempt stays current instead of advancing',
    () async {
      final voice = _FailingStartVoicePlayer();
      final player = MusicPlayerController.forTest(player: voice);

      final first = track(1);
      final second = track(2);
      player.play(first, visibleQueue: [first, second], toggleIfActive: false);
      await settle();

      // The failed track stays current: skipping to the next one silently
      // would look like playback never started.
      expect(player.current?.music?.file?.id, 1);
      expect(player.isPlaying, isFalse);
      expect(player.isLoading, isFalse);
      expect(
        voice.starts,
        2,
        reason: 'one silent recovery attempt, then report',
      );
      expect(player.playbackFailureReports, 1);
    },
  );

  test(
    'a retry after the reported failure goes through the start path again',
    () async {
      final voice = _FailingStartVoicePlayer(failuresBeforeSuccess: 2);
      final player = MusicPlayerController.forTest(player: voice);

      final only = track(7);
      player.play(only, visibleQueue: [only], toggleIfActive: false);
      await settle();
      expect(player.isPlaying, isFalse);
      expect(player.playbackFailureReports, 1);

      // The system Play command retries a retained-but-stopped track.
      player.resume();
      await settle();
      expect(player.isPlaying, isTrue);
      expect(voice.starts, 3);
      expect(player.playbackFailureReports, 1);
    },
  );
}

/// A [VoicePlayer] whose native start fails a number of times before
/// succeeding, mirroring a startPlayer that throws or never completes. Its
/// [VoicePlayer.onFailed] is the controller's handler, so failures flow the
/// production path.
class _FailingStartVoicePlayer extends VoicePlayer {
  _FailingStartVoicePlayer({this.failuresBeforeSuccess = 1 << 30});

  final int failuresBeforeSuccess;
  int starts = 0;
  bool _active = false;
  bool _paused = false;

  @override
  bool get isPaused => _paused;

  @override
  Future<void> toggleAudio(TdFileRef? file) async {
    starts++;
    _active = true;
    if (starts <= failuresBeforeSuccess) {
      isPlaying = false;
      notifyListeners();
      onFailed?.call(file!.id, StateError('start failed'));
      return;
    }
    _paused = false;
    isPlaying = true;
    position = Duration.zero;
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    if (!_active || _paused) return;
    _paused = false;
    isPlaying = true;
    notifyListeners();
  }
}
