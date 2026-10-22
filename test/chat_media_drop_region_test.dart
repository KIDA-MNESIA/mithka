import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_media_drop_region.dart';
import 'package:mithka/chat/outgoing_attachment.dart';
import 'package:mithka/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS drops route only to the visible enabled chat under the pointer',
    (tester) async {
      final received = <String>[];
      final image = File('assets/penguin.png').absolute.path;
      final navigator = GlobalKey<NavigatorState>();
      Widget region(String name, {bool enabled = true}) => ChatMediaDropRegion(
        key: ValueKey(name),
        enabled: enabled,
        onImagesDropped: (List<OutgoingAttachment> images) async {
          expect(images.single.path, image);
          received.add(name);
        },
        child: const ColoredBox(color: Colors.white),
      );
      Widget app({bool right = true}) => MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(extensions: [AppColors.light]),
        home: Row(
          children: [
            Expanded(child: region('left')),
            Expanded(
              child: right ? region('right', enabled: false) : const SizedBox(),
            ),
          ],
        ),
      );
      await tester.pumpWidget(app());
      await _drop(tester, const Offset(200, 200), [image]);
      expect(received, ['left']);
      await _drop(tester, const Offset(600, 200), [image]);
      expect(received, ['left']);

      // Disposing another region must not unregister the surviving chat.
      await tester.pumpWidget(app(right: false));
      await _drop(tester, const Offset(200, 200), [image]);
      expect(received, ['left', 'left']);

      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covered chat')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _drop(tester, const Offset(200, 200), [image]);
      expect(received, ['left', 'left']);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await _drop(tester, const Offset(200, 200), [image]);
      expect(received, ['left', 'left', 'left']);

      await _nativeCall(
        tester,
        const MethodCall('dropStartedAt', {
          'id': 'stale-drop',
          'x': 200.0,
          'y': 200.0,
        }),
      );
      await tester.pumpWidget(app());
      await _nativeCall(
        tester,
        MethodCall('dropImagesAt', {
          'id': 'stale-drop',
          'paths': [image],
        }),
      );
      expect(received, ['left', 'left', 'left']);
    },
  );
}

Future<void> _nativeCall(WidgetTester tester, MethodCall call) async {
  await tester.runAsync(() async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'mithka/media_drop',
      const StandardMethodCodec().encodeMethodCall(call),
      (_) {},
    );
  });
  await tester.pumpAndSettle();
}

Future<void> _drop(
  WidgetTester tester,
  Offset position,
  List<String> paths,
) async {
  const codec = StandardMethodCodec();
  await tester.runAsync(() async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'mithka/media_drop',
      codec.encodeMethodCall(
        MethodCall('dropStartedAt', {
          'id': 'test-drop',
          'x': position.dx,
          'y': position.dy,
        }),
      ),
      (_) {},
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'mithka/media_drop',
      codec.encodeMethodCall(
        MethodCall('dropImagesAt', {'id': 'test-drop', 'paths': paths}),
      ),
      (_) {},
    );
  });
  await tester.pumpAndSettle();
}
