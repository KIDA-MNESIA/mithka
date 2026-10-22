import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/chats/qr_scanner_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/platform/camera_permission.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  testWidgets('camera stops in background and resumes on return', (
    tester,
  ) async {
    final permission = _CameraPermission(CameraPermissionAccess.granted);
    final camera = _CameraController();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        home: QrScannerView(
          cameraPermission: permission,
          scannerController: camera,
          scannerBuilder: (_, _, _) => const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    camera.value = camera.value.copyWith(isInitialized: true, isRunning: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(camera.events, ['stop', 'start']);
    expect(camera.value.isRunning, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('camera permission can be retried without reopening scanner', (
    tester,
  ) async {
    final permission = _CameraPermission(CameraPermissionAccess.denied);
    await _pumpCamera(tester, permission);
    expect(find.byKey(const ValueKey('fake-camera')), findsNothing);
    permission.access = CameraPermissionAccess.granted;
    await tester.tap(find.byKey(const ValueKey('qr-scanner-camera-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-camera')), findsOneWidget);
    expect(permission.requests, 2);
  });

  testWidgets('camera mounts after permission is granted in system settings', (
    tester,
  ) async {
    final permission = _CameraPermission(CameraPermissionAccess.blocked);
    await _pumpCamera(tester, permission);
    await tester.tap(find.byKey(const ValueKey('qr-scanner-camera-retry')));
    await tester.pumpAndSettle();
    expect(permission.settingsOpened, 1);
    expect(find.byKey(const ValueKey('fake-camera')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    permission.access = CameraPermissionAccess.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-camera')), findsOneWidget);
    expect(permission.requests, 1);
  });
  test(
    'recognizes Telegram QR links without treating external links as deep links',
    () {
      expect(isTelegramQrValue('https://t.me/mithka'), isTrue);
      expect(isTelegramQrValue('t.me/mithka'), isTrue);
      expect(isTelegramQrValue('tg://resolve?domain=mithka'), isTrue);
      expect(isTelegramQrValue('https://example.com/t.me/mithka'), isFalse);
      expect(isTelegramQrValue('plain text'), isFalse);
    },
  );

  test('deduplicates multiple QR candidates and preserves their types', () {
    final candidates = qrCandidatesFromCapture(
      const BarcodeCapture(
        barcodes: [
          Barcode(rawValue: 'https://t.me/mithka', type: BarcodeType.url),
          Barcode(rawValue: 'https://t.me/mithka', type: BarcodeType.url),
          Barcode(
            rawValue: 'WIFI:T:WPA;S:Test;P:password;;',
            type: BarcodeType.wifi,
          ),
        ],
      ),
    );

    expect(candidates, hasLength(2));
    expect(candidates.first.isTelegram, isTrue);
    expect(candidates.last.type, BarcodeType.wifi);
    expect(candidates.last.isUrl, isFalse);
  });

  testWidgets('plus menu exposes QR scanner as its first action', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topRight,
          child: PlusMenu(onSelect: (value) => selected = value),
        ),
      ),
    );

    final expectedLabel = AppStrings.t(AppStringKeys.chatListScanQrCode);
    final labels = tester.widgetList<Text>(find.byType(Text)).toList();
    expect(labels.first.data, expectedLabel);
    await tester.tap(find.text(expectedLabel));
    expect(selected, AppStringKeys.chatListScanQrCode);
  });
}

Future<void> _pumpCamera(
  WidgetTester tester,
  _CameraPermission permission,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: [AppColors.light]),
      home: QrScannerView(
        cameraPermission: permission,
        scannerBuilder: (_, _, _) =>
            const ColoredBox(key: ValueKey('fake-camera'), color: Colors.black),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _CameraPermission implements CameraPermissionGateway {
  _CameraPermission(this.access);
  CameraPermissionAccess access;
  int requests = 0;
  int settingsOpened = 0;
  @override
  Future<CameraPermissionAccess> check() async => access;
  @override
  Future<CameraPermissionAccess> request() async {
    requests++;
    return access;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

class _CameraController extends MobileScannerController {
  final events = <String>[];
  @override
  Future<void> start({
    CameraFacing? cameraDirection,
    CameraLensType? cameraLensType,
  }) async {
    events.add('start');
    value = value.copyWith(isRunning: true);
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    value = value.copyWith(isRunning: false);
  }
}
