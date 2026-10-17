// Geometry of the split shell's mini player, measured through the real shell
// at each iPad surface.
//
// Baseline before the card was docked in the chat list column, measured with
// this harness at 1366x1024: the bar was a full-window strip
// Rect(0, 942, 1366, 1024) -- 1366x82 -- sitting below the tab bar, the chat
// list column was 420 wide, and the conversation pane (chatConversationContent)
// ended at y=942, 82pt short of the window. At 1024x1366 the strip was
// Rect(0, 1284, 1024, 1366) with the transcript ending at 1284.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/chat_deep_link_controller.dart';
import 'package:mithka/app/main_tab_view.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/chat/music_player_controller.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/components/drawer_controller.dart' as dc;
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late StreamController<Map<String, dynamic>> updates;
  final player = MusicPlayerController.shared;
  final deepLinks = ChatDeepLinkController.shared;

  setUpAll(() async {
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => _response(request),
        send: (_) async {},
        updates: updates.stream,
      ),
    );
    // Real TDLib reports the connection state once when a client exists; the
    // chat-list header reads that report rather than asking for it.
    updates.add({
      '@type': 'updateConnectionState',
      'state': {'@type': 'connectionStateReady'},
    });
    await Future<void>.delayed(Duration.zero);
  });

  setUp(() {
    clearChatMemoryCaches();
    deepLinks.consumePending();
  });

  tearDown(() {
    deepLinks.consumePending();
    player
      ..current = null
      ..queue = const []
      ..hidden = true
      ..collapsed = false;
  });

  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets('iPad landscape docks the card inside the chat list column', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      const size = Size(1366, 1024);
      await _pumpShellWithTrack(tester, size);
      final list = tester.getRect(
        find.byKey(const ValueKey('tablet-list-pane')),
      );
      final card = tester.getRect(find.byKey(musicMiniPlayerCardKey));
      final tabTop = tester
          .getRect(find.byKey(const ValueKey('bottom-tab-0')))
          .top;
      final transcript = tester.getRect(
        find.byKey(const ValueKey('chatConversationContent')),
      );

      // No window-wide strip anywhere in the shell.
      expect(find.byType(GlobalMusicPlayerBar), findsNothing);

      // A floating card inside the list column, 8pt in from both of its
      // edges, and never wider than the column.
      expect(card.left, greaterThanOrEqualTo(list.left + 8 - 0.01));
      expect(card.right, lessThanOrEqualTo(list.right - 8 + 0.01));
      expect(card.width, lessThanOrEqualTo(list.width - 16 + 0.01));
      expect(card.width, closeTo(list.width - 16, 0.01));

      // Compact: 56pt budget for artwork, two text lines and transport.
      expect(card.height, lessThanOrEqualTo(56));
      expect(card.height, musicMiniPlayerCardHeight);

      // Docked above the tab bar, not below it, nor under the window edge.
      expect(card.bottom, lessThanOrEqualTo(tabTop));
      expect(tabTop - card.bottom, greaterThanOrEqualTo(8 - 0.01));
      expect(tabTop - card.bottom, lessThanOrEqualTo(12));

      // The conversation pane owns the window's full height again.
      expect(transcript.bottom, closeTo(size.height, 0.01));
      expect(transcript.height, greaterThan(size.height - 120));

      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iPad portrait keeps the card in the narrower column', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      const size = Size(1024, 1366);
      await _pumpShellWithTrack(tester, size);
      final list = tester.getRect(
        find.byKey(const ValueKey('tablet-list-pane')),
      );
      final card = tester.getRect(find.byKey(musicMiniPlayerCardKey));
      final tabTop = tester
          .getRect(find.byKey(const ValueKey('bottom-tab-0')))
          .top;
      final transcript = tester.getRect(
        find.byKey(const ValueKey('chatConversationContent')),
      );

      expect(find.byType(GlobalMusicPlayerBar), findsNothing);
      expect(list.width, lessThan(420));
      expect(card.left, greaterThanOrEqualTo(list.left + 8 - 0.01));
      expect(card.right, lessThanOrEqualTo(list.right - 8 + 0.01));
      expect(card.width, lessThanOrEqualTo(list.width - 16 + 0.01));
      expect(card.height, lessThanOrEqualTo(56));
      expect(card.bottom, lessThanOrEqualTo(tabTop));
      expect(tabTop - card.bottom, greaterThanOrEqualTo(8 - 0.01));
      expect(transcript.bottom, closeTo(size.height, 0.01));

      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iPhone keeps the full-width docked bar in both orientations', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      for (final size in const [Size(390, 844), Size(844, 390)]) {
        await _pumpShellWithTrack(tester, size, openChat: false);
        final bar = tester.getRect(find.byType(GlobalMusicPlayerBar));

        expect(find.byKey(musicMiniPlayerCardKey), findsNothing);
        expect(bar.width, closeTo(size.width, 0.01));
        expect(bar.height, musicPlayerBarHeight);
        expect(bar.bottom, lessThanOrEqualTo(size.height));
        expect(tester.takeException(), isNull);
        await _disposeShell(tester);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('dragging the card left dismisses the player', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pumpShellWithTrack(tester, const Size(1366, 1024));
      final card = find.byKey(musicMiniPlayerCardKey);

      // The dismiss target appears while the card is dragged over it.
      final gesture = await tester.startGesture(tester.getCenter(card));
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-90, 0));
      await tester.pump();
      expect(find.byKey(musicMiniPlayerTrashKey), findsOneWidget);

      // Releasing under the distance threshold leaves the player in place.
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump(const Duration(milliseconds: 120));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 250));
      expect(player.isVisible, isTrue);
      expect(card, findsOneWidget);

      await tester.drag(card, const Offset(-240, 0));
      await tester.pump(const Duration(milliseconds: 250));
      await _settle(tester);

      expect(player.current, isNull);
      expect(player.isVisible, isFalse);
      expect(find.byKey(musicMiniPlayerCardKey), findsNothing);
      expect(find.byType(GlobalMusicPlayerBar), findsNothing);
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('dragging the card right collapses it to a pill and back', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pumpShellWithTrack(tester, const Size(1366, 1024));
      final card = find.byKey(musicMiniPlayerCardKey);
      final expandedWidth = tester.getSize(card).width;

      await tester.drag(card, const Offset(220, 0));
      await _settle(tester);

      expect(player.collapsed, isTrue);
      final pill = tester.getRect(card);
      expect(pill.height, musicMiniPlayerPillHeight);
      expect(pill.height, lessThan(musicMiniPlayerCardHeight));
      expect(pill.width, closeTo(expandedWidth, 0.01));

      // The pill restores the expanded card on a tap.
      await tester.tapAt(pill.center);
      await _settle(tester);
      expect(player.collapsed, isFalse);
      expect(tester.getSize(card).height, musicMiniPlayerCardHeight);

      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a long title ellipsizes instead of overflowing the card', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      const longTitle =
          'An exceptionally long track title that keeps going well past the '
          'width of the chat list column and then some more';
      await _pumpShellWithTrack(
        tester,
        const Size(1024, 1366),
        track: _track(title: longTitle),
      );
      final card = tester.getRect(find.byKey(musicMiniPlayerCardKey));
      final title = tester.widget<Text>(find.text(longTitle));

      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(tester.getSize(find.text(longTitle)).width, lessThan(card.width));
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the window-level collapsed player stands down for a dock', (
    tester,
  ) async {
    player
      ..current = _track()
      ..queue = [_track()];
    player.collapse();
    addTearDown(() => player.collapsed = false);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              GlobalMusicPlayerOverlay(),
              Align(
                alignment: Alignment.bottomLeft,
                child: SizedBox(width: 320, child: MusicMiniPlayerDock()),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(player.hasDockedMiniPlayerHost, isTrue);
    expect(find.byKey(musicCollapsedOverlayKey), findsNothing);
    // The dock draws the collapsed pill itself.
    final pill = tester.getRect(find.byKey(musicMiniPlayerCardKey));
    expect(pill.height, musicMiniPlayerPillHeight);
    expect(pill.width, closeTo(320 - 2 * musicMiniPlayerEdgeInset, 0.01));

    // Without the dock the window-level player comes back.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [GlobalMusicPlayerOverlay()])),
      ),
    );
    await tester.pump();
    expect(player.hasDockedMiniPlayerHost, isFalse);
    expect(find.byKey(musicCollapsedOverlayKey), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _pumpShellWithTrack(
  WidgetTester tester,
  Size size, {
  bool openChat = true,
  ChatMessage? track,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await _pumpMainShell(tester);

  final playing = track ?? _track();
  MusicPlayerController.shared
    ..current = playing
    ..queue = [playing];
  MusicPlayerController.shared.expand();
  await tester.pump();

  if (openChat && find.byType(ChatListView).evaluate().isNotEmpty) {
    final list = tester.widget<ChatListView>(find.byType(ChatListView).first);
    list.onChatSelected?.call(ChatListSelection.fromChat(_chat()));
    await _settle(tester);
  }
  await _settle(tester);
}

ChatMessage _track({
  String title = 'Song title',
  String performer = 'Artist',
}) => ChatMessage(
  id: 101,
  isOutgoing: false,
  text: '',
  date: 1,
  chatId: -42,
  senderName: 'Music chat',
  music: MessageMusic(
    title: title,
    performer: performer,
    duration: 200,
    file: TdFileRef(id: 303),
  ),
);

ChatSummary _chat() => ChatSummary(
  id: -42,
  title: 'Music chat',
  lastMessage: '',
  lastMessageId: 0,
  date: 0,
  unreadCount: 0,
  order: 1,
  isMuted: false,
  kind: ChatKind.group,
);

Map<String, dynamic> _message(int id) => {
  '@type': 'message',
  'id': id,
  'chat_id': -42,
  'date': id,
  'is_outgoing': true,
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': 'Post $id'},
  },
};

Map<String, dynamic> _response(Map<String, dynamic> request) =>
    switch (request['@type']) {
      'getChat' => {
        '@type': 'chat',
        'id': request['chat_id'],
        'title': 'Music chat',
        'view_as_topics': false,
        'type': {
          '@type': 'chatTypeSupergroup',
          'supergroup_id': 42,
          'is_channel': false,
        },
        'permissions': {
          '@type': 'chatPermissions',
          'can_send_basic_messages': true,
        },
      },
      'getSupergroup' => {
        '@type': 'supergroup',
        'id': 42,
        'is_forum': false,
        'status': {'@type': 'chatMemberStatusMember'},
      },
      'getChatHistory' => {
        '@type': 'messages',
        'messages': [_message(70)],
      },
      'getMessage' => _message(request['message_id'] as int),
      'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
      _ => {'@type': 'ok'},
    };

Future<void> _pumpMainShell(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'showChannelsTab': false,
    'hideChatContextPane': false,
    'showMomentsTab': false,
    'communitiesEnabled': false,
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
  addTearDown(auth.dispose);
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: true, textScaler: TextScaler.noScaling),
          child: child!,
        ),
        home: const MainSplitRootView(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _disposeShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Chat-list cache warming uses delayed no-op guards after disposal.
  await tester.pump(const Duration(seconds: 6));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}
