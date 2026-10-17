import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view.dart'
    show ChatView, ReactionUsersSheetFrame, clearChatMemoryCaches;
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

// Reaction reactors sheet: the chip's count opens the list, a row opens the
// sender, and each reactor can be reported through
// `reportMessageReactions` once the message grants `can_report_reactions`.

const _chatId = -1000000004242;
const _messageId = 5;
const _meId = 1;

Map<String, dynamic> _reaction(int count, {bool chosen = false}) => {
  '@type': 'messageReaction',
  'type': {'@type': 'reactionTypeEmoji', 'emoji': '👍'},
  'total_count': count,
  'is_chosen': chosen,
};

Map<String, dynamic> _message({bool canReportReactions = true}) => {
  '@type': 'message',
  'id': _messageId,
  'chat_id': _chatId,
  'date': 1785862260 + _messageId,
  'is_outgoing': false,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': 2},
  if (canReportReactions) 'can_report_reactions': true,
  'interaction_info': {
    'reactions': {
      'reactions': [_reaction(3)],
    },
  },
  'content': {
    '@type': 'messageText',
    'text': {
      '@type': 'formattedText',
      'text': 'reacted message',
      'entities': <Map<String, dynamic>>[],
    },
  },
};

Map<String, dynamic> _chatJson() => {
  '@type': 'chat',
  'id': _chatId,
  'title': 'Group chat',
  'type': {
    '@type': 'chatTypeSupergroup',
    'supergroup_id': -_chatId - 1000000000000,
    'is_channel': false,
  },
  'last_read_inbox_message_id': 5,
  'unread_count': 0,
  'permissions': {'can_send_basic_messages': true},
};

Map<String, dynamic> _user(int id, String firstName, {bool deleted = false}) =>
    {
      '@type': 'user',
      'id': id,
      'first_name': firstName,
      'type': {'@type': deleted ? 'userTypeDeleted' : 'userTypeRegular'},
    };

Map<String, dynamic> _addedReaction(int userId, int date) => {
  '@type': 'addedReaction',
  'sender_id': {'@type': 'messageSenderUser', 'user_id': userId},
  'reaction_type': {'@type': 'reactionTypeEmoji', 'emoji': '👍'},
  'date': date,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  L10nFixtures.load().install();

  late List<Map<String, dynamic>> requests;
  late bool canReportReactions;
  late bool reactionsFail;
  late bool reportFails;
  late bool reactionsLoadedOnce;

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(Map<String, dynamic>.from(request));
          switch (request['@type']) {
            case 'getChat':
              return _chatJson();
            case 'getChatHistory':
              return {
                '@type': 'messages',
                'total_count': 1,
                'messages': [_message(canReportReactions: canReportReactions)],
              };
            case 'getMe':
              return _user(_meId, 'Me');
            case 'getUser':
              final id = request['user_id'] as int;
              return switch (id) {
                2 => _user(2, 'Alice'),
                3 => _user(3, '', deleted: true),
                _ => _user(id, 'Me'),
              };
            case 'getSupergroup':
              return {'@type': 'supergroup', 'id': -_chatId - 1000000000000};
            case 'getSupergroupFullInfo':
              return {'@type': 'supergroupFullInfo', 'member_count': 3};
            case 'getMessageAddedReactions':
              if (reactionsFail) {
                throw StateError('reactions unavailable');
              }
              reactionsLoadedOnce = true;
              return {
                '@type': 'addedReactions',
                'total_count': 3,
                'reactions': [
                  _addedReaction(2, 1785862261),
                  _addedReaction(_meId, 1785862262),
                  _addedReaction(3, 1785862263),
                ],
              };
            case 'reportMessageReactions':
              if (reportFails) {
                throw StateError('report unavailable');
              }
              return {'@type': 'ok'};
            case 'getMessageAvailableReactions':
              return {
                '@type': 'availableReactions',
                'top_reactions': [
                  {
                    '@type': 'availableReaction',
                    'type': {'@type': 'reactionTypeEmoji', 'emoji': '👍'},
                    'needs_premium': false,
                  },
                ],
                'recent_reactions': <Map<String, dynamic>>[],
                'popular_reactions': <Map<String, dynamic>>[],
                'allow_custom_emoji': false,
                'are_tags': false,
                'unavailability_reason': null,
              };
            case 'getOption':
              return {'@type': 'optionValueBoolean', 'value': false};
            case 'addMessageReaction' || 'removeMessageReaction':
              return {'@type': 'ok'};
            default:
              return {'@type': 'ok'};
          }
        },
        send: (_) async {},
        updates: const Stream.empty(),
      ),
    );
  });
  tearDownAll(TdClient.shared.closeProxy);

  late ThemeController theme;
  late TranslationController translation;
  late List<(int, String)> openedProfiles;

  setUp(() async {
    requests = [];
    canReportReactions = true;
    reactionsFail = false;
    reportFails = false;
    reactionsLoadedOnce = false;
    openedProfiles = [];
    SharedPreferences.setMockInitialValues({});
    theme = ThemeController(await SharedPreferences.getInstance());
    translation = TranslationController(await SharedPreferences.getInstance());
  });
  tearDown(() {
    clearChatMemoryCaches();
    theme.dispose();
    translation.dispose();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    clearChatMemoryCaches();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<TranslationController>.value(
            value: translation,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(extensions: [AppColors.light]),
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChatView(
            chatId: _chatId,
            title: 'Group',
            onOpenUserProfile: (userId, name) =>
                openedProfiles.add((userId, name)),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(
      find.byKey(const ValueKey('messageTapTarget-$_messageId')),
      findsOneWidget,
      reason: 'the fixture message must render',
    );
  }

  Future<void> openReactions(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey('reactionCount-$_messageId-emoji:👍')),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.byType(ReactionUsersSheetFrame), findsOneWidget);
  }

  Finder inSheet(Finder matching) => find.descendant(
    of: find.byType(ReactionUsersSheetFrame),
    matching: matching,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('tapping a reaction count opens its reactor list', (
    tester,
  ) async {
    await pumpChat(tester);
    await openReactions(tester);

    final loads = requests
        .where((request) => request['@type'] == 'getMessageAddedReactions')
        .toList();
    expect(loads, hasLength(1));
    expect(loads.single['chat_id'], _chatId);
    expect(loads.single['message_id'], _messageId);
    expect(loads.single['reaction_type'], {
      '@type': 'reactionTypeEmoji',
      'emoji': '👍',
    });
    expect(inSheet(find.text('Alice')), findsOneWidget);
    expect(
      requests.any((request) => request['@type'] == 'addMessageReaction'),
      isFalse,
    );

    await settle(tester);
  });

  testWidgets('tapping the reaction emoji still toggles the reaction', (
    tester,
  ) async {
    await pumpChat(tester);

    await tester.tap(find.text('👍'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      requests.where((request) => request['@type'] == 'addMessageReaction'),
      hasLength(1),
    );
    expect(
      requests.singleWhere(
        (request) => request['@type'] == 'addMessageReaction',
      )['reaction_type'],
      {'@type': 'reactionTypeEmoji', 'emoji': '👍'},
    );
    expect(
      requests.where(
        (request) => request['@type'] == 'getMessageAddedReactions',
      ),
      isEmpty,
    );
    expect(find.byType(ReactionUsersSheetFrame), findsNothing);

    await settle(tester);
  });

  testWidgets('a row opens its sender and a deleted account row does not', (
    tester,
  ) async {
    await pumpChat(tester);
    await openReactions(tester);
    // A deleted account has no name of its own; the sheet shows the same
    // placeholder the rest of the app uses for it.
    expect(inSheet(find.text('Deleted Account')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reactionUser-2')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(openedProfiles, [(2, 'Alice')]);

    await tester.tap(find.text('Deleted Account'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(openedProfiles, [(2, 'Alice')]);
    expect(find.byKey(const ValueKey('reactionUser-3')), findsNothing);

    await settle(tester);
  });

  testWidgets('report is offered for other live senders and names the sender', (
    tester,
  ) async {
    await pumpChat(tester);
    await openReactions(tester);

    // Sender 2 is another user, sender 1 is me and sender 3 is deleted.
    expect(find.byKey(const ValueKey('reactionUserReport-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('reactionUserReport-1')), findsNothing);
    expect(find.byKey(const ValueKey('reactionUserReport-3')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reactionUserReport-2')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Report reaction'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Report reaction?'), findsOneWidget);
    expect(
      find.text(
        'Report the reaction from Alice as objectionable or abusive content?',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Report'));
    await tester.pump(const Duration(milliseconds: 400));

    final reports = requests
        .where((request) => request['@type'] == 'reportMessageReactions')
        .toList();
    expect(reports, hasLength(1));
    expect(reports.single, {
      '@type': 'reportMessageReactions',
      'chat_id': _chatId,
      'message_id': _messageId,
      'sender_id': {'@type': 'messageSenderUser', 'user_id': 2},
    });
    expect(find.text('Reaction reported'), findsOneWidget);

    await settle(tester);
  });

  testWidgets('without the message permission no report action is offered', (
    tester,
  ) async {
    canReportReactions = false;
    await pumpChat(tester);
    await openReactions(tester);

    expect(find.byKey(const ValueKey('reactionUserReport-2')), findsNothing);

    await settle(tester);
  });

  testWidgets('a failed report keeps the sheet open and shows the error', (
    tester,
  ) async {
    reportFails = true;
    await pumpChat(tester);
    await openReactions(tester);

    await tester.tap(find.byKey(const ValueKey('reactionUserReport-2')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Report reaction'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Report'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.textContaining('Could not report the reaction'),
      findsOneWidget,
    );
    expect(find.byType(ReactionUsersSheetFrame), findsOneWidget);
    expect(tester.takeException(), isNull);

    await settle(tester);
  });

  testWidgets('a failed reactor load offers a retry that reloads the rows', (
    tester,
  ) async {
    reactionsFail = true;
    await pumpChat(tester);
    await openReactions(tester);
    expect(inSheet(find.text('Could not load reactions')), findsOneWidget);
    expect(inSheet(find.text('Alice')), findsNothing);

    reactionsFail = false;
    await tester.tap(find.byKey(const ValueKey('reaction-users-retry')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(reactionsLoadedOnce, isTrue);
    expect(inSheet(find.text('Alice')), findsOneWidget);
    expect(inSheet(find.text('Could not load reactions')), findsNothing);

    await settle(tester);
  });
}
