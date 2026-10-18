import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/notifications/notification_preferences.dart';
import 'package:mithka/settings/notification_settings_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _privateScope = 'notificationSettingsScopePrivateChats';
const _groupScope = 'notificationSettingsScopeGroupChats';
const _channelScope = 'notificationSettingsScopeChannelChats';

void main() {
  final queries = <Map<String, dynamic>>[];

  /// Replies for the private scope's exception list, consumed in order. A
  /// [List] answers with those chat ids, a [Map] is returned verbatim (an
  /// error), and a [Completer] holds the request open.
  final privateExceptionReplies = <Object>[];
  final chatsById = <int, Map<String, dynamic>>{};
  var resetFails = false;

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          queries.add(request);
          switch (request['@type']) {
            case 'getScopeNotificationSettings':
              final scope = (request['scope'] as Map)['@type'];
              return _scopeSettings(soundId: scope == _privateScope ? 5 : 0);
            case 'getChatNotificationSettingsExceptions':
              final scope = (request['scope'] as Map)['@type'];
              if (scope == _privateScope &&
                  privateExceptionReplies.isNotEmpty) {
                final reply = privateExceptionReplies.removeAt(0);
                if (reply is Completer<Map<String, dynamic>>) {
                  return reply.future;
                }
                if (reply is Map<String, dynamic>) return reply;
                return _chats(reply as List<int>);
              }
              return _chats(const []);
            case 'getStoryNotificationSettingsExceptions':
              return _chats(const []);
            case 'getSavedNotificationSounds':
              return {
                '@type': 'notificationSounds',
                'total_count': 0,
                'sounds': <Map<String, dynamic>>[],
              };
            case 'getCurrentState':
              return {'@type': 'updates', 'updates': <Map<String, dynamic>>[]};
            case 'getChat':
              final chat = chatsById[request['chat_id']];
              if (chat == null) {
                return {
                  '@type': 'error',
                  'code': 400,
                  'message': 'Chat not found',
                };
              }
              return chat;
            case 'setChatNotificationSettings':
              if (resetFails) {
                return {'@type': 'error', 'code': 400, 'message': 'Rejected'};
              }
              return {'@type': 'ok'};
          }
          return {'@type': 'ok'};
        },
        send: (request) async => queries.add(request),
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
  });

  setUp(() {
    queries.clear();
    privateExceptionReplies.clear();
    chatsById.clear();
    resetFails = false;
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    NotificationPreferences.shared.initialize(preferences);
    final theme = ThemeController(preferences);
    addTearDown(theme.dispose);

    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: NotificationSettingsView(),
        ),
      ),
    );
    await _settle(tester);
  }

  Future<void> openExceptions(WidgetTester tester, String scope) async {
    await tester.tap(find.byKey(ValueKey('notification-exceptions-$scope')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);
  }

  List<Map<String, dynamic>> exceptionQueries(String scope) => queries
      .where(
        (request) =>
            request['@type'] == 'getChatNotificationSettingsExceptions' &&
            (request['scope'] as Map)['@type'] == scope,
      )
      .toList();

  testWidgets('only scopes with exceptions expose the tappable count', (
    tester,
  ) async {
    privateExceptionReplies.addAll([
      [101],
      [101],
    ]);
    chatsById[101] = _chat(101, 'Alice', {
      'use_default_mute_for': false,
      'mute_for': 2147483647,
    });

    await pumpSettings(tester);

    expect(
      find.byKey(const ValueKey('notification-exceptions-$_privateScope')),
      findsOneWidget,
    );
    expect(find.text('1 exception'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('notification-exceptions-$_groupScope')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('notification-exceptions-$_channelScope')),
      findsNothing,
    );

    await openExceptions(tester, _privateScope);

    expect(
      find.byKey(const ValueKey('notification-exceptions-sheet')),
      findsOneWidget,
    );
    // The count has its own tap target; it must not also push the scope page.
    expect(find.text('Preview'), findsNothing);
  });

  testWidgets('the sheet asks for the scope and describes each deviation', (
    tester,
  ) async {
    privateExceptionReplies.addAll([
      [101, 102],
      [101, 102],
    ]);
    chatsById[101] = _chat(101, 'Alice', {
      'use_default_mute_for': false,
      'mute_for': 2147483647,
    });
    chatsById[102] = _chat(102, 'Bob', {
      'use_default_sound': false,
      'sound_id': 0,
    });

    await pumpSettings(tester);
    await openExceptions(tester, _privateScope);

    final requests = exceptionQueries(_privateScope);
    expect(requests, hasLength(2));
    // Sound-only exceptions must be listed too, so a chat whose only
    // deviation is a custom sound still shows up and can be reset.
    expect(requests.last['compare_sound'], isTrue);

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Muted'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Sound off'), findsOneWidget);
  });

  testWidgets('reset writes defaults, drops the row and re-reads the count', (
    tester,
  ) async {
    privateExceptionReplies.addAll([
      [101],
      [101],
      <int>[],
    ]);
    chatsById[101] = _chat(101, 'Alice', {
      'use_default_mute_for': false,
      'mute_for': 2147483647,
    });

    await pumpSettings(tester);
    await openExceptions(tester, _privateScope);
    expect(find.text('Alice'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('notification-exception-reset-101')),
    );
    await _settle(tester);

    final reset = queries.singleWhere(
      (request) => request['@type'] == 'setChatNotificationSettings',
    );
    expect(reset['chat_id'], 101);
    final settings = reset['notification_settings'] as Map<String, dynamic>;
    const defaultFlags = [
      'use_default_mute_for',
      'use_default_sound',
      'use_default_show_preview',
      'use_default_mute_stories',
      'use_default_story_sound',
      'use_default_show_story_poster',
      'use_default_disable_pinned_message_notifications',
      'use_default_disable_mention_notifications',
    ];
    expect(
      settings.keys.where((key) => key.startsWith('use_default_')),
      unorderedEquals(defaultFlags),
    );
    for (final flag in defaultFlags) {
      expect(settings[flag], isTrue, reason: flag);
    }

    expect(find.text('Alice'), findsNothing);
    expect(
      find.byKey(const ValueKey('notification-exception-reset-101')),
      findsNothing,
    );
    expect(exceptionQueries(_privateScope), hasLength(3));
  });

  testWidgets('a failed reset keeps the row and reports the failure', (
    tester,
  ) async {
    privateExceptionReplies.addAll([
      [101],
      [101],
    ]);
    chatsById[101] = _chat(101, 'Alice', {
      'use_default_mute_for': false,
      'mute_for': 2147483647,
    });
    resetFails = true;

    await pumpSettings(tester);
    await openExceptions(tester, _privateScope);

    await tester.tap(
      find.byKey(const ValueKey('notification-exception-reset-101')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Alice'), findsOneWidget);
    expect(
      find.text('Couldn’t reset this chat to the scope settings.'),
      findsOneWidget,
    );

    // Let the toast finish so no timer survives the test.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('the sheet stays in a loading state until the list arrives', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    privateExceptionReplies.addAll([
      [101],
      pending,
    ]);
    chatsById[101] = _chat(101, 'Alice', {
      'use_default_mute_for': false,
      'mute_for': 2147483647,
    });

    await pumpSettings(tester);
    await openExceptions(tester, _privateScope);

    expect(
      find.byKey(const ValueKey('notification-exceptions-loading')),
      findsOneWidget,
    );
    expect(find.text('Alice'), findsNothing);

    pending.complete(_chats([101]));
    await _settle(tester);

    expect(find.text('Alice'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('notification-exceptions-loading')),
      findsNothing,
    );
  });

  testWidgets('the sheet offers a retry when the list request fails', (
    tester,
  ) async {
    privateExceptionReplies.addAll([
      [101],
      {'@type': 'error', 'code': 400, 'message': 'Unavailable'},
      [101],
    ]);
    chatsById[101] = _chat(101, 'Alice', {
      'use_default_mute_for': false,
      'mute_for': 2147483647,
    });

    await pumpSettings(tester);
    await openExceptions(tester, _privateScope);

    expect(
      find.byKey(const ValueKey('notification-exceptions-error')),
      findsOneWidget,
    );
    expect(find.text('Alice'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('notification-exceptions-retry')),
    );
    await _settle(tester);

    expect(find.text('Alice'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('notification-exceptions-error')),
      findsNothing,
    );
  });

  testWidgets('the sheet reports an empty list instead of a blank panel', (
    tester,
  ) async {
    privateExceptionReplies.addAll([
      [101],
      <int>[],
    ]);

    await pumpSettings(tester);
    await openExceptions(tester, _privateScope);

    expect(
      find.byKey(const ValueKey('notification-exceptions-empty')),
      findsOneWidget,
    );
    expect(find.text('No chats differ from this scope.'), findsOneWidget);
  });
}

Map<String, dynamic> _scopeSettings({
  int muteFor = 0,
  int soundId = 0,
  bool showPreview = true,
}) => {
  '@type': 'scopeNotificationSettings',
  'mute_for': muteFor,
  'sound_id': soundId,
  'show_preview': showPreview,
  'use_default_mute_stories': true,
  'mute_stories': false,
  'story_sound_id': 0,
  'show_story_poster': true,
  'disable_pinned_message_notifications': false,
  'disable_mention_notifications': false,
};

Map<String, dynamic> _chats(List<int> chatIds) => {
  '@type': 'chats',
  'total_count': chatIds.length,
  'chat_ids': chatIds,
};

Map<String, dynamic> _chat(
  int id,
  String title,
  Map<String, dynamic> notificationSettings,
) => {
  '@type': 'chat',
  'id': id,
  'title': title,
  'photo': null,
  'notification_settings': {
    '@type': 'chatNotificationSettings',
    'use_default_mute_for': true,
    'mute_for': 0,
    'use_default_sound': true,
    'sound_id': 0,
    'use_default_show_preview': true,
    'show_preview': true,
    'use_default_mute_stories': true,
    'mute_stories': false,
    'use_default_story_sound': true,
    'story_sound_id': 0,
    'use_default_show_story_poster': true,
    'show_story_poster': true,
    'use_default_disable_pinned_message_notifications': true,
    'disable_pinned_message_notifications': false,
    'use_default_disable_mention_notifications': true,
    'disable_mention_notifications': false,
    ...notificationSettings,
  },
};

/// Pumps a few frames so the sequential scope reads finish without waiting on
/// the loading indicator's endless animation.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}
