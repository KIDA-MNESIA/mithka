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

// Tapping the conversation that is already open in the split pane has to take
// the reader to its newest message. It used to assign an equal selection, so
// the tap did nothing at all and the reader stayed where they had scrolled.

const _chatId = -77;
const _messageCount = 80;

void main() {
  late StreamController<Map<String, dynamic>> updates;
  final requests = <Map<String, dynamic>>[];

  setUpAll(() async {
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(request);
          return _response(request);
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
    updates.add({
      '@type': 'updateConnectionState',
      'state': {'@type': 'connectionStateReady'},
    });
    await Future<void>.delayed(Duration.zero);
  });
  setUp(() {
    requests.clear();
    clearChatMemoryCaches();
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets('tapping the open conversation again shows its newest message', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _setSurfaceSize(tester, const Size(1000, 900));
      await _pumpMainShell(tester);

      tester.widget<ChatListView>(find.byType(ChatListView)).onChatSelected!(
        ChatListSelection.fromChat(_chat()),
      );
      await _settle(tester);

      // The chat opens at the newest message.
      expect(find.byType(ChatView), findsOneWidget);
      expect(
        find.text('Post $_messageCount', findRichText: true),
        findsOneWidget,
      );
      final openChat = tester.state(find.byType(ChatView));

      // Scroll into older history until the newest message is off screen.
      await tester.drag(
        find.text('Post $_messageCount', findRichText: true),
        const Offset(0, 600),
      );
      await _settle(tester);
      expect(
        find.text('Post $_messageCount', findRichText: true),
        findsNothing,
      );
      final scrolledAway = _transcriptPosition(tester);
      expect(scrolledAway.pixels, lessThan(scrolledAway.maxScrollExtent - 200));

      // Tapping the same conversation again is a request for the latest
      // message, not a no-op and not a rebuild of the pane the reader is in.
      tester.widget<ChatListView>(find.byType(ChatListView)).onChatSelected!(
        ChatListSelection.fromChat(_chat()),
      );
      await _settle(tester);

      expect(
        find.text('Post $_messageCount', findRichText: true),
        findsOneWidget,
      );
      final returned = _transcriptPosition(tester);
      expect(returned.pixels, returned.maxScrollExtent);
      expect(tester.state(find.byType(ChatView)), same(openChat));
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a jump target in the open conversation still jumps', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _setSurfaceSize(tester, const Size(1000, 900));
      await _pumpMainShell(tester);

      tester.widget<ChatListView>(find.byType(ChatListView)).onChatSelected!(
        ChatListSelection.fromChat(_chat()),
      );
      await _settle(tester);
      final openChat = tester.state(find.byType(ChatView));

      // A deep link to a specific message inside the same chat must open that
      // message; it must not be read as "show me the newest message".
      ChatDeepLinkController.shared.openChat(
        chatId: _chatId,
        title: 'Group',
        messageId: 4,
      );
      await _settle(tester);

      expect(find.text('Post 4', findRichText: true), findsOneWidget);
      expect(
        find.text('Post $_messageCount', findRichText: true),
        findsNothing,
      );
      // A jump target rebuilds the pane with the jump, so it is a new state.
      expect(tester.state(find.byType(ChatView)), isNot(same(openChat)));
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

ChatSummary _chat() => ChatSummary(
  id: _chatId,
  title: 'Group',
  lastMessage: 'Post $_messageCount',
  lastMessageId: _messageCount,
  date: _messageCount,
  unreadCount: 0,
  order: 1,
  isMuted: false,
  kind: ChatKind.group,
);

Map<String, dynamic> _message(int id) => {
  '@type': 'message',
  'id': id,
  'chat_id': _chatId,
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
        'title': 'Group',
        'type': {
          '@type': 'chatTypeSupergroup',
          'supergroup_id': 77,
          'is_channel': false,
        },
        'permissions': {
          '@type': 'chatPermissions',
          'can_send_basic_messages': true,
        },
      },
      'getSupergroup' => {
        '@type': 'supergroup',
        'id': 77,
        'is_forum': false,
        'status': {'@type': 'chatMemberStatusMember'},
      },
      'getChatHistory' => {
        '@type': 'messages',
        'messages': [for (var id = _messageCount; id >= 1; id--) _message(id)],
      },
      'getMessage' => _message(request['message_id'] as int),
      'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
      _ => {'@type': 'ok'},
    };

Future<void> _pumpMainShell(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'showChannelsTab': false,
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
          ).copyWith(textScaler: TextScaler.noScaling),
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

Future<void> _setSurfaceSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

/// The vertical transcript scroll position — the only scrollable in the pane
/// that can actually move.
ScrollPosition _transcriptPosition(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.byType(Scrollable))
    .map((state) => state.position)
    .firstWhere((position) => position.maxScrollExtent > 0);

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}
