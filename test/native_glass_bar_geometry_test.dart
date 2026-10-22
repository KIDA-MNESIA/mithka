//
//  native_glass_bar_geometry_test.dart
//
//  The iOS glass bar hosts a native Liquid Glass surface whose glass never
//  draws tabs or selection: the app-owned row, its pill indicator, and every
//  gesture stay in Flutter on top of the surface. One path therefore serves the
//  compact phone bottom bar and the tablet split shell's sidebar column — the
//  old "system bar paints its capsule against the window, not this column"
//  failure mode cannot recur, because nothing system-drawn is positioned
//  relative to tab slots anymore.
//
//  The native host keeps the same window containment as the Flutter glass bar:
//  the surface stops inside the bottom safe area instead of reaching under the
//  home indicator, and the row keeps the shared lateral, top, and capsule
//  insets, so both hosts draw the bar at the same rect.
//
//  Under flutter test the real UIKit view never exists, so the whole file
//  installs a mock for the platform-view creation channel and the per-view
//  method channel; the mock only records and answers the way the native side
//  would (nothing to answer).
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/chat_deep_link_controller.dart';
import 'package:mithka/app/liquid_glass_bottom_bar.dart';
import 'package:mithka/app/main_tab_view.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/components/drawer_controller.dart' as dc;
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _surfaceKey = ValueKey('native-glass-surface');
const _indicatorKey = ValueKey('liquid-glass-selection');
const _firstSlotKey = ValueKey('bottom-tab-0');

/// An iPhone 14-style window: 390x844 with the 34px home-indicator inset.
const _phoneSize = Size(390, 844);
const _phoneBottomInset = 34.0;

/// The bar geometry both glass hosts share: the 62px control row inside a 5px
/// capsule inset, with 14px lateral and 8px top margins, and a 10px gap above
/// the surface's own bottom (the Flutter bar's `minimum` for the safe area).
const _rowHeight = 62.0;
const _capsuleInset = 5.0;
const _surfaceHeight = _rowHeight + 2 * _capsuleInset;
const _surfaceBottomGap = 10.0;
const _sideMargin = 14.0;

void main() {
  final updates = StreamController<Map<String, dynamic>>.broadcast();
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });
  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => _response(request),
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  testWidgets('iOS split shell hosts the native glass with app-owned tabs', (
    tester,
  ) async {
    await onIOS(() async {
      installMockGlassSurface(tester);
      await _pumpShell(tester, const Size(900, 800));
      // The native surface is present behind the app-owned bar.
      expect(find.byKey(_surfaceKey), findsOneWidget);
      expect(find.byType(UiKitView), findsOneWidget);
      // The selection pill and the tab slots are all Flutter-drawn, so the
      // pill still covers the selected tab exactly inside the narrow sidebar
      // column — the geometry no longer depends on where UIKit thinks the
      // window-bottom bar is.
      final indicator = find.byKey(_indicatorKey);
      expect(indicator, findsOneWidget);
      final slots = find.byKey(_firstSlotKey);
      expect(tester.getRect(indicator), tester.getRect(slots));
      // A window with no bell keeps the shared capsule gap below the surface
      // and draws no phantom bar of its own.
      final surface = tester.getRect(find.byKey(_surfaceKey));
      expect(surface.bottom, 800 - _surfaceBottomGap);
      expect(surface.height, _surfaceHeight);
      expect(
        tester.getRect(slots).bottom,
        800 - _surfaceBottomGap - _capsuleInset,
      );
      await _dispose(tester);
    });
  });

  testWidgets('compact iOS window hosts the native glass, taps stay alive', (
    tester,
  ) async {
    await onIOS(() async {
      installMockGlassSurface(tester);
      await _pumpShell(tester, _phoneSize);
      expect(find.byKey(_surfaceKey), findsOneWidget);
      expect(find.byType(UiKitView), findsOneWidget);
      final indicator = find.byKey(_indicatorKey);
      final slots = find.byKey(_firstSlotKey);
      expect(tester.getRect(indicator), tester.getRect(slots));
      // An uninset window still leaves the shared capsule gap at its bottom.
      expect(
        tester.getRect(find.byKey(_surfaceKey)).bottom,
        _phoneSize.height - _surfaceBottomGap,
      );
      // Tapping a tab still selects it: the row above the glass owns gestures.
      await tester.tap(find.byKey(const ValueKey('bottom-tab-2')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester.getRect(find.byKey(_indicatorKey)),
        tester.getRect(find.byKey(const ValueKey('bottom-tab-2'))),
      );
      await _dispose(tester);
    });
  });

  // Regression: the iOS host returned the platform surface without the
  // SafeArea containment the other two bar paths apply, so on a phone window
  // the surface (and the 62px row above it) reached y=844 and drew under the
  // home indicator instead of stopping at y=810.
  testWidgets('iOS glass surface stays clear of the home indicator', (
    tester,
  ) async {
    await onIOS(() async {
      installMockGlassSurface(tester);
      final homeIndicatorTop = _phoneSize.height - _phoneBottomInset;
      await _pumpShell(
        tester,
        _phoneSize,
        insets: const FakeViewPadding(bottom: _phoneBottomInset),
      );
      final surface = find.byKey(_surfaceKey);
      expect(surface, findsOneWidget);
      final surfaceRect = tester.getRect(surface);
      // The glass stops at or above the home indicator's top edge...
      expect(surfaceRect.bottom, lessThanOrEqualTo(homeIndicatorTop));
      // ...but it is still the bottom bar, not a surface collapsed by the fix.
      expect(surfaceRect.bottom, homeIndicatorTop);
      expect(surfaceRect.height, _surfaceHeight);
      expect(surfaceRect.left, _sideMargin);
      expect(surfaceRect.right, _phoneSize.width - _sideMargin);
      expect(tester.getRect(find.byType(UiKitView)), surfaceRect);
      // The tab controls stay above the home-indicator region too.
      final slot = find.byKey(_firstSlotKey);
      expect(tester.getRect(slot).bottom, lessThanOrEqualTo(homeIndicatorTop));
      expect(tester.getRect(slot).bottom, homeIndicatorTop - _capsuleInset);
      expect(tester.getRect(slot), tester.getRect(find.byKey(_indicatorKey)));
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  });

  // The fix requirement in one assertion: whatever the platform host, the row
  // and the surface land on the same rect the Flutter glass bar uses.
  testWidgets('native host mirrors the Flutter glass bar geometry', (
    tester,
  ) async {
    await onIOS(() async {
      installMockGlassSurface(tester);
      const insets = FakeViewPadding(bottom: _phoneBottomInset);
      await _pumpShell(tester, _phoneSize, insets: insets);
      final nativeSurface = tester.getRect(find.byKey(_surfaceKey));
      final nativeSlot = tester.getRect(find.byKey(_firstSlotKey));

      // Same window, non-iOS target: the Flutter glass bar is the host.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await _pumpShell(tester, _phoneSize, insets: insets);
      final bar = find.byType(LiquidGlassBottomBar);
      expect(bar, findsOneWidget);
      expect(find.byKey(_surfaceKey), findsNothing);
      final stadium = find.descendant(
        of: bar,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ClipRRect &&
              widget.borderRadius == BorderRadius.circular(AppRadius.pill),
        ),
      );
      expect(stadium, findsOneWidget);
      expect(tester.getRect(stadium), nativeSurface);
      expect(tester.getRect(find.byKey(_firstSlotKey)), nativeSlot);
      expect(tester.getRect(find.byKey(_indicatorKey)), nativeSlot);
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  });

  testWidgets('narrow phone keeps the native surface inside its insets', (
    tester,
  ) async {
    await onIOS(() async {
      installMockGlassSurface(tester);
      const size = Size(320, 568);
      await _pumpShell(
        tester,
        size,
        insets: const FakeViewPadding(top: 47, bottom: 34),
      );
      final surfaceRect = tester.getRect(find.byKey(_surfaceKey));
      expect(surfaceRect.bottom, lessThanOrEqualTo(size.height - 34));
      // The status-bar inset never leaks into the bar's own height.
      expect(surfaceRect.height, _surfaceHeight);
      // The lateral margins never push the row outside the window.
      expect(surfaceRect.left, _sideMargin);
      expect(surfaceRect.right, size.width - _sideMargin);
      final slot = find.byKey(_firstSlotKey);
      expect(tester.getRect(slot).bottom, lessThanOrEqualTo(size.height - 34));
      expect(tester.getRect(slot), tester.getRect(find.byKey(_indicatorKey)));
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  });

  testWidgets('split shell column honors the bottom inset too', (tester) async {
    await onIOS(() async {
      installMockGlassSurface(tester);
      // No camera inset and no usable split width, so the glass bar stays in
      // the narrow sidebar column.
      await _pumpShell(
        tester,
        const Size(900, 800),
        insets: const FakeViewPadding(bottom: 34),
      );
      final surfaceRect = tester.getRect(find.byKey(_surfaceKey));
      expect(surfaceRect.bottom, lessThanOrEqualTo(800 - 34));
      expect(surfaceRect.height, _surfaceHeight);
      final slot = find.byKey(_firstSlotKey);
      expect(tester.getRect(slot).bottom, lessThanOrEqualTo(800 - 34));
      expect(tester.getRect(slot), tester.getRect(find.byKey(_indicatorKey)));
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  });

  testWidgets('RTL glass host keeps containment and the channel flag', (
    tester,
  ) async {
    await onIOS(() async {
      final mock = installMockGlassSurface(tester);
      final homeIndicatorTop = _phoneSize.height - _phoneBottomInset;
      await _pumpShell(
        tester,
        _phoneSize,
        insets: const FakeViewPadding(bottom: _phoneBottomInset),
        textDirection: TextDirection.rtl,
      );
      expect(mock.createdParams, isNotEmpty);
      for (final params in mock.createdParams) {
        expect(params['rtl'], isTrue);
      }
      final surfaceRect = tester.getRect(find.byKey(_surfaceKey));
      expect(surfaceRect.bottom, lessThanOrEqualTo(homeIndicatorTop));
      expect(surfaceRect.height, _surfaceHeight);
      final slot = find.byKey(_firstSlotKey);
      expect(tester.getRect(slot).bottom, lessThanOrEqualTo(homeIndicatorTop));
      // Both the row and the pill mirror: the first slot sits on the right.
      expect(tester.getRect(slot), tester.getRect(find.byKey(_indicatorKey)));
      expect(tester.getRect(slot).left, greaterThan(_phoneSize.width / 2));
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  });
}

/// Mocks platform-view creation and the per-view channel for the whole test.
/// Under flutter test the real UIKit glass never exists, so the mock answers
/// the way the native side would (nothing to answer) while recording the
/// creation parameters each surface was configured with.
class GlassSurfaceMock {
  GlassSurfaceMock(this._messenger);

  final TestDefaultBinaryMessenger _messenger;
  final List<Map<Object?, Object?>> createdParams = [];
  final Map<int, MethodChannel> _channels = {};

  void install() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final arguments = call.arguments as Map;
        final id = arguments['id'] as int;
        createdParams.add(
          const StandardMessageCodec().decodeMessage(
                ByteData.sublistView(arguments['params'] as Uint8List),
              )
              as Map<Object?, Object?>,
        );
        final channel = MethodChannel('mithka/native_glass/$id');
        _channels[id] = channel;
        _messenger.setMockMethodCallHandler(channel, (call) async => null);
      }
      return null;
    });
  }

  void dispose() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final channel in _channels.values) {
      _messenger.setMockMethodCallHandler(channel, null);
    }
    _channels.clear();
  }
}

/// Installs the mock for the current test and tears it down with the test.
GlassSurfaceMock installMockGlassSurface(WidgetTester tester) {
  final mock = GlassSurfaceMock(tester.binding.defaultBinaryMessenger);
  mock.install();
  addTearDown(mock.dispose);
  return mock;
}

/// Runs [body] with iOS as the target platform, clearing the override before
/// the test body returns (the framework asserts it is unset at teardown).
Future<void> onIOS(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _pumpShell(
  WidgetTester tester,
  Size size, {
  FakeViewPadding insets = FakeViewPadding.zero,
  TextDirection textDirection = TextDirection.ltr,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = insets;
  tester.view.viewPadding = insets;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  SharedPreferences.setMockInitialValues({
    'showChannelsTab': true,
    'showMomentsTab': true,
    'communitiesEnabled': false,
    'liquidGlassBottomBar': true,
  });
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  final accounts = AccountStore(prefs);
  final auth = AuthManager();
  final translation = TranslationController(prefs);
  final drawer = dc.DrawerController();
  final deepLinks = ChatDeepLinkController.shared;
  deepLinks.consumePending();

  addTearDown(theme.dispose);
  addTearDown(accounts.dispose);
  addTearDown(translation.dispose);
  addTearDown(drawer.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<AppLocaleController>.value(
          value: AppLocaleController(prefs),
        ),
        ChangeNotifierProvider<AccountStore>.value(value: accounts),
        ChangeNotifierProvider<AuthManager>.value(value: auth),
        ChangeNotifierProvider<TranslationController>.value(value: translation),
        ChangeNotifierProvider<ChatDeepLinkController>.value(value: deepLinks),
        ChangeNotifierProvider<dc.DrawerController>.value(value: drawer),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          brightness: Brightness.light,
          extensions: [AppColors.light],
        ),
        builder: (context, child) =>
            Directionality(textDirection: textDirection, child: child!),
        home: const MainSplitRootView(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Chat-list cache warming uses delayed no-op guards after disposal.
  await tester.pump(const Duration(seconds: 6));
}

Map<String, dynamic> _response(Map<String, dynamic> request) =>
    switch (request['@type']) {
      'getChats' => {'@type': 'chats', 'chat_ids': <int>[]},
      'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
      'getConnectionState' => {'@type': 'connectionStateReady'},
      _ => {'@type': 'ok'},
    };
