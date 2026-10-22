import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/components/photo_avatar.dart';
import 'package:mithka/tdlib/avatar_animation_index.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
// Installs a deterministic implementation of the public video_player API.
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String imagePath;
  late String videoPath;
  late _AvatarVideoPlatform platform;
  late VideoPlayerPlatform previousPlatform;
  late TdFileRef photo;
  late ValueNotifier<bool> deleted;
  var nextPhoto = 810000;
  var fullInfoReads = 0;
  Completer<Map<String, dynamic>>? pendingFullInfo;

  Map<String, dynamic> fullInfo() => {
    '@type': 'userFullInfo',
    'photo': {
      '@type': 'chatPhoto',
      'id': photo.photoId,
      'small_animation': {
        '@type': 'animatedChatPhoto',
        'file': {
          '@type': 'file',
          'id': photo.id + 1,
          'local': {'path': videoPath, 'is_downloading_completed': true},
        },
      },
    },
  };

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'mithka-avatar-lifecycle',
    );
    imagePath = '${directory.path}/still.png';
    videoPath = '${directory.path}/animation.mp4';
    await File(imagePath).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aU1sAAAAASUVORK5CYII=',
      ),
    );
    await File(videoPath).writeAsBytes(const [0]);
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          if (request['@type'] == 'getUserFullInfo') {
            fullInfoReads++;
            return pendingFullInfo?.future ?? Future.value(fullInfo());
          }
          return {'@type': 'ok'};
        },
        send: (_) async {},
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await directory.delete(recursive: true);
  });
  setUp(() {
    fullInfoReads = 0;
    pendingFullInfo = null;
    previousPlatform = VideoPlayerPlatform.instance;
    platform = _AvatarVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    photo = TdFileRef(
      id: nextPhoto,
      localPath: imagePath,
      hasAnimation: true,
      photoId: nextPhoto + 10,
    );
    nextPhoto += 100;
    AvatarAnimationIndex.shared.observe(0, {
      '@type': 'user',
      'id': photo.id,
      'profile_photo': {
        'has_animation': true,
        'small': {'id': photo.id},
      },
    });
    deleted = ValueNotifier(false);
  });
  tearDown(() {
    deleted.dispose();
    VideoPlayerPlatform.instance = previousPlatform;
  });

  Future<void> frames(WidgetTester tester, [int count = 20]) async {
    for (var i = 0; i < count; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ValueListenableBuilder<bool>(
            valueListenable: deleted,
            builder: (_, isDeleted, _) => PhotoAvatar(
              key: const ValueKey('avatar'),
              title: 'Account',
              photo: photo,
              isDeleted: isDeleted,
            ),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await frames(tester, 3);
    });
  }

  testWidgets('initially deleted avatar never resolves or creates a player', (
    tester,
  ) async {
    deleted.value = true;
    await mount(tester);
    await frames(tester);
    expect(find.byKey(ghostAvatarKey), findsOneWidget);
    expect(fullInfoReads, 0);
    expect(platform.created, isEmpty);
  });
  testWidgets(
    'deleting an avatar with the same photo releases its native player',
    (tester) async {
      await mount(tester);
      await frames(tester);
      expect(platform.played, hasLength(1));
      deleted.value = true;
      await tester.pump();
      await frames(tester);
      expect(find.byKey(ghostAvatarKey), findsOneWidget);
      expect(platform.disposed, contains(platform.created.single));
      deleted.value = false;
      await tester.pump();
      await frames(tester);
      expect(platform.played, hasLength(2));
    },
  );
  testWidgets('deletion invalidates a pending avatar metadata resolution', (
    tester,
  ) async {
    pendingFullInfo = Completer<Map<String, dynamic>>();
    await mount(tester);
    await frames(tester, 2);
    expect(fullInfoReads, 1);
    deleted.value = true;
    await tester.pump();
    pendingFullInfo!.complete(fullInfo());
    await frames(tester);
    expect(find.byKey(ghostAvatarKey), findsOneWidget);
    expect(platform.created, isEmpty);
  });
  testWidgets(
    'a late native initialization after deletion never starts playback',
    (tester) async {
      platform.autoInitialize = false;
      await mount(tester);
      await frames(tester);
      expect(platform.created, hasLength(1));
      expect(platform.played, isEmpty);
      deleted.value = true;
      await tester.pump();
      platform.initialize(platform.created.single);
      await frames(tester);
      expect(platform.played, isEmpty);
      expect(platform.disposed, platform.created);
    },
  );
  testWidgets('a late native initialization after disposal never plays', (
    tester,
  ) async {
    platform.autoInitialize = false;
    await mount(tester);
    await frames(tester);
    expect(platform.created, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    platform.initialize(platform.created.single);
    await frames(tester);
    expect(platform.played, isEmpty);
    expect(platform.disposed, platform.created);
  });

  testWidgets('a metadata reply after disposal never creates a player', (
    tester,
  ) async {
    pendingFullInfo = Completer<Map<String, dynamic>>();
    await mount(tester);
    await frames(tester, 2);
    expect(fullInfoReads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    pendingFullInfo!.complete(fullInfo());
    await frames(tester);
    expect(platform.created, isEmpty);
  });
}

class _AvatarVideoPlatform extends VideoPlayerPlatform {
  final _events = <int, StreamController<VideoEvent>>{};
  final created = <int>[];
  final played = <int>[];
  final disposed = <int>[];
  bool autoInitialize = true;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = created.length + 1;
    created.add(id);
    _events[id] = StreamController<VideoEvent>.broadcast();
    return id;
  }

  void initialize(int id) {
    _events[id]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 2),
        size: const Size(40, 40),
      ),
    );
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    if (autoInitialize) scheduleMicrotask(() => initialize(playerId));
    return _events[playerId]!.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    played.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
}
