import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/channels/topic_chat_view.dart';
import 'package:mithka/chat/channel_direct_messages_service.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/config/build_flags.dart';
import 'package:mithka/settings/country_chat_blocker.dart';
import 'package:mithka/settings/country_message_filter.dart';
import 'package:mithka/settings/ghost_mode_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Enabled-build variant: run with
/// `flutter test --dart-define=I_DONT_FUCKING_CARE_ABOUT_TOS=true
/// test/ghost_mode_enabled_test.dart`. Every test self-skips when the define
/// is absent so the default CI run stays green.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final updates = StreamController<Map<String, dynamic>>.broadcast();
  final requests = <Map<String, dynamic>>[];
  late SharedPreferences prefs;

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (_) async => <String, dynamic>{'@type': 'ok'},
        send: (request) async => requests.add(request),
        updates: updates.stream,
      ),
    );
  });

  setUp(() async {
    requests.clear();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // Reset the shared controller against a clean store for every test.
    GhostModeController.shared.initialize(prefs);
  });

  tearDownAll(() async {
    await GhostModeController.shared.setGlobalEnabled(false);
    await GhostModeController.shared.setChatException(
      -10042,
      GhostChatException.defaultState,
    );
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  /// Matrix cell: global on/off × chat exception × dimension switch.
  Future<void> initializeWith({
    bool globalEnabled = true,
    bool blockReadReceipts = true,
    bool blockTyping = true,
    bool blockStoryReads = true,
    GhostChatException chat = GhostChatException.defaultState,
  }) async {
    SharedPreferences.setMockInitialValues({
      'ghost_mode.enabled': globalEnabled,
      'ghost_mode.blockReadReceipts': blockReadReceipts,
      'ghost_mode.blockTyping': blockTyping,
      'ghost_mode.blockStoryReads': blockStoryReads,
      if (chat != GhostChatException.defaultState)
        'ghost_mode.chat.-10042': chat.storedValue,
    });
    prefs = await SharedPreferences.getInstance();
    GhostModeController.shared.initialize(prefs);
    // initialize() replays the `online` option onto every registered client;
    // drain that burst so tests observe only their own requests.
    await Future<void>.delayed(Duration.zero);
    requests.clear();
  }

  if (!allowTelegramTosViolations) {
    test('skipped: this file requires I_DONT_FUCKING_CARE_ABOUT_TOS', () {
      expect(allowTelegramTosViolations, isFalse);
    });
    return;
  }

  test('flag is on in this variant', () {
    expect(allowTelegramTosViolations, isTrue);
  });

  group('read receipts decision matrix', () {
    for (final global in [false, true]) {
      for (final exception in GhostChatException.values) {
        test('global=$global exception=${exception.name}', () async {
          await initializeWith(globalEnabled: global, chat: exception);
          final expected = global && exception != GhostChatException.forceAllow;
          expect(
            GhostModeController.shared.shouldBlockRead(-10042).isBlock,
            expected,
            reason: 'global=$global exception=${exception.name}',
          );
          expect(
            GhostModeController.shared.shouldBlockRead(-999).isBlock,
            global,
            reason: 'other chats follow the global switch',
          );
        });
      }
    }
  });

  group('typing decision matrix', () {
    for (final global in [false, true]) {
      for (final exception in GhostChatException.values) {
        test('global=$global exception=${exception.name}', () async {
          await initializeWith(globalEnabled: global, chat: exception);
          final expected = global && exception != GhostChatException.forceAllow;
          expect(
            GhostModeController.shared.shouldBlockTyping(-10042).isBlock,
            expected,
            reason: 'global=$global exception=${exception.name}',
          );
        });
      }
    }
  });

  group('stories decision matrix', () {
    for (final global in [false, true]) {
      for (final dimension in [false, true]) {
        for (final exception in GhostChatException.values) {
          test(
            'global=$global dimension=$dimension exception=${exception.name}',
            () async {
              await initializeWith(
                globalEnabled: global,
                blockStoryReads: dimension,
                chat: exception,
              );
              // With the dimension on, every chat intercepts except
              // force-allow ones. With it off (the user wants working seen
              // markers), only force-block chats still intercept.
              final expected =
                  global &&
                  (dimension
                      ? exception != GhostChatException.forceAllow
                      : exception == GhostChatException.forceBlock);
              expect(
                GhostModeController.shared.shouldBlockStories(-10042).isBlock,
                expected,
                reason:
                    'global=$global dimension=$dimension '
                    'exception=${exception.name}',
              );
            },
          );
        }
      }
    }
  });

  group('online status', () {
    test('shared only while globally on and the dimension is on', () async {
      await initializeWith();
      expect(GhostModeController.shared.shouldShareOnline(), isTrue);
      await GhostModeController.shared.setHideOnline(false);
      expect(GhostModeController.shared.shouldShareOnline(), isFalse);
      await GhostModeController.shared.setHideOnline(true);
      await GhostModeController.shared.setGlobalEnabled(false);
      expect(GhostModeController.shared.shouldShareOnline(), isFalse);
    });

    test('per-chat exceptions do not apply to the online option', () async {
      await initializeWith(chat: GhostChatException.forceAllow);
      expect(GhostModeController.shared.shouldShareOnline(), isTrue);
    });

    test('toggle pushes the online option to the registered client', () async {
      await initializeWith(globalEnabled: false);
      requests.clear();
      await GhostModeController.shared.setGlobalEnabled(true);
      expect(requests.where((request) => request['@type'] == 'setOption'), [
        {
          '@type': 'setOption',
          'name': 'online',
          'value': {'@type': 'optionValueBoolean', 'value': false},
        },
      ]);
      requests.clear();
      await GhostModeController.shared.setGlobalEnabled(false);
      expect(
        requests
            .where((request) => request['@type'] == 'setOption')
            .single['value']['value'],
        isTrue,
      );
    });

    test('toggling off restores the online option', () async {
      await initializeWith();
      requests.clear();
      await GhostModeController.shared.setGlobalEnabled(false);
      expect(
        requests
            .where((request) => request['@type'] == 'setOption')
            .single['value']['value'],
        isTrue,
        reason: 'online goes back to true once ghost mode is off',
      );
    });
  });

  test(
    'read receipts skip the server report but keep local clearing',
    () async {
      await initializeWith();
      final message = ChatMessage(
        id: 301,
        text: 'mention',
        date: 1,
        isOutgoing: false,
        containsUnreadMention: true,
      );
      final viewModel = ChatViewModel(
        chatId: -10042,
        title: 'Group',
        markReadOnOpen: false,
        sessionMessages: [message],
      );
      addTearDown(viewModel.dispose);
      viewModel.applyLiveUpdateForTesting({
        '@type': 'updateChatUnreadMentionCount',
        'chat_id': -10042,
        'unread_mention_count': 1,
      });

      viewModel.markVisibleMessagesViewed([message]);
      await Future<void>.delayed(Duration.zero);

      expect(requests, isEmpty, reason: 'the viewMessages report is withheld');
      expect(
        viewModel.unreadMentionCount,
        0,
        reason: 'local badge still clears',
      );
      expect(message.containsUnreadMention, isFalse);
    },
  );

  test('force-allow chat reports reads again', () async {
    await initializeWith(chat: GhostChatException.forceAllow);
    final message = ChatMessage(
      id: 401,
      text: 'visible',
      date: 1,
      isOutgoing: false,
    );
    final viewModel = ChatViewModel(
      chatId: -10042,
      title: 'Group',
      markReadOnOpen: false,
      sessionMessages: [message],
    );
    addTearDown(viewModel.dispose);

    viewModel.markVisibleMessagesViewed([message]);
    await Future<void>.delayed(Duration.zero);

    expect(requests.single['@type'], 'viewMessages');
    expect(requests.single['force_read'], isTrue);
  });

  test('typing is withheld in ghost chats and sent otherwise', () async {
    await initializeWith();
    final viewModel = ChatViewModel(
      chatId: -10042,
      title: 'Group',
      markReadOnOpen: false,
    );
    addTearDown(viewModel.dispose);

    viewModel.sendTyping();
    await Future<void>.delayed(Duration.zero);
    expect(requests, isEmpty);

    await GhostModeController.shared.setChatException(
      -10042,
      GhostChatException.forceAllow,
    );
    viewModel.sendTyping();
    await Future<void>.delayed(Duration.zero);
    expect(requests.single['@type'], 'sendChatAction');
  });

  test('opening the chat marks it read locally without reporting', () async {
    await initializeWith();
    final viewModel = ChatViewModel(
      chatId: -10042,
      title: 'Group',
      markReadOnOpen: false,
    );
    addTearDown(viewModel.dispose);
    viewModel.markChatReadStateReadyForTesting();
    viewModel.applyLiveUpdateForTesting({
      '@type': 'updateChatReadInbox',
      'chat_id': -10042,
      'last_read_inbox_message_id': 0,
      'unread_count': 3,
    });
    viewModel.applyLiveUpdateForTesting({
      '@type': 'updateChatIsMarkedAsUnread',
      'chat_id': -10042,
      'is_marked_as_unread': true,
    });
    requests.clear();

    await viewModel.markLoadedMessagesRead();

    expect(
      requests.where(
        (request) =>
            request['@type'] == 'viewMessages' ||
            request['@type'] == 'toggleChatIsMarkedAsUnread',
      ),
      isEmpty,
      reason: 'both server reports are withheld',
    );
    expect(viewModel.unreadCount, 0, reason: 'local unread count still clears');
  });

  test('opening the chat still reports in a force-allow chat', () async {
    await initializeWith(chat: GhostChatException.forceAllow);
    final message = ChatMessage(
      id: 501,
      text: 'latest',
      date: 1,
      isOutgoing: false,
    );
    final viewModel = ChatViewModel(
      chatId: -10042,
      title: 'Group',
      markReadOnOpen: false,
      sessionMessages: [message],
    );
    addTearDown(viewModel.dispose);
    viewModel.markChatReadStateReadyForTesting();
    viewModel.applyLiveUpdateForTesting({
      '@type': 'updateChatReadInbox',
      'chat_id': -10042,
      'last_read_inbox_message_id': 0,
      'unread_count': 3,
    });
    requests.clear();

    await viewModel.markLoadedMessagesRead();

    expect(
      requests.map((request) => request['@type']),
      contains('viewMessages'),
    );
  });

  test('controller persists a round-trip', () async {
    await initializeWith();
    await GhostModeController.shared.setGlobalEnabled(true);
    await GhostModeController.shared.setBlockStoryReads(false);
    await GhostModeController.shared.setChatException(
      -10042,
      GhostChatException.forceBlock,
    );

    // A fresh instance reads the same state from disk.
    GhostModeController.shared.initialize(prefs);
    expect(GhostModeController.shared.globalEnabled, isTrue);
    expect(GhostModeController.shared.blockStoryReads, isFalse);
    expect(
      GhostModeController.shared.exceptionFor(-10042),
      GhostChatException.forceBlock,
    );
  });

  test('story reads are withheld and resume with the dimension off', () async {
    await initializeWith();
    // openStory lives in the story viewer; here we pin the decision the
    // viewer consults, plus the persisted round-trip of the dimension.
    expect(
      GhostModeController.shared.shouldBlockStories(-10042).isBlock,
      isTrue,
    );
    await GhostModeController.shared.setBlockStoryReads(false);
    expect(
      GhostModeController.shared.shouldBlockStories(-10042).isBlock,
      isFalse,
    );
    // A force-block exception keeps intercepting while the dimension is off.
    await GhostModeController.shared.setChatException(
      -10042,
      GhostChatException.forceBlock,
    );
    expect(
      GhostModeController.shared.shouldBlockStories(-10042).isBlock,
      isTrue,
    );
  });

  test('forum topic viewport reports read without ghost, not with', () async {
    // Force-allow keeps the ordinary report path alive under ghost mode.
    await initializeWith(chat: GhostChatException.forceAllow);
    expect(shouldReportForumTopicReads(-10042), isTrue);
    await initializeWith();
    expect(shouldReportForumTopicReads(-10042), isFalse);
    // The topic surface reports through the same decision the chat view
    // uses, so a force-block chat stays withheld with the dimension off
    // and a default chat reports again once ghost mode is disabled.
    await GhostModeController.shared.setGlobalEnabled(false);
    expect(shouldReportForumTopicReads(-10042), isTrue);
  });

  test(
    'direct-messages topic loads keep reporting without ghost only',
    () async {
      await initializeWith();
      final requests = <Map<String, dynamic>>[];
      final client = _RecordingTdClient(requests);
      final service = ChannelDirectMessageTopicController(
        chatId: -10042,
        topicId: 7,
        client: client,
      );
      await service.loadHistory();
      expect(
        requests.any(
          (request) =>
              request['@type'] == 'viewMessages' &&
              request['source']?['@type'] ==
                  'messageSourceDirectMessagesChatTopicHistory',
        ),
        isFalse,
      );

      requests.clear();
      await initializeWith(chat: GhostChatException.forceAllow);
      final reporting = ChannelDirectMessageTopicController(
        chatId: -10042,
        topicId: 7,
        client: _RecordingTdClient(requests),
      );
      await reporting.loadHistory();
      expect(
        requests.any(
          (request) =>
              request['@type'] == 'viewMessages' &&
              request['source']?['@type'] ==
                  'messageSourceDirectMessagesChatTopicHistory',
        ),
        isTrue,
      );
    },
  );

  test('country-blocked reads follow the ghost read decision', () async {
    Future<List<Map<String, dynamic>>> blockedReadsWith(
      GhostChatException chat,
    ) async {
      await initializeWith(chat: chat);
      final requests = <Map<String, dynamic>>[];
      final blocker = CountryChatBlocker(
        filter: await _countryFilter(),
        query: (request, _) async {
          requests.add(request);
          return switch (request['@type']) {
            'getChat' => {
              '@type': 'chat',
              'id': -10042,
              'type': {'@type': 'chatTypePrivate', 'user_id': 7},
              'action_bar': _firstContactActionBar('JP'),
              'notification_settings': {
                '@type': 'chatNotificationSettings',
                'use_default_mute_for': true,
                'mute_for': 0,
                'use_default_sound': false,
                'sound_id': 99,
                'use_default_show_preview': false,
                'show_preview': false,
              },
            },
            'getUser' => {
              '@type': 'user',
              'id': 7,
              'phone_number': '+81 90 1234 5678',
            },
            _ => {'@type': 'ok'},
          };
        },
      );
      await blocker.handleIncomingMessage(_countryIncoming(), clientId: 3);
      return requests;
    }

    final ghosted = await blockedReadsWith(GhostChatException.defaultState);
    expect(
      ghosted.any((request) => request['@type'] == 'viewMessages'),
      isFalse,
    );

    final allowed = await blockedReadsWith(GhostChatException.forceAllow);
    expect(
      allowed.any((request) => request['@type'] == 'viewMessages'),
      isTrue,
    );
  });
}

Map<String, dynamic> _topicMessage(int id) => {
  '@type': 'message',
  'id': id,
  'chat_id': -10042,
  'date': id,
  'is_outgoing': false,
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': 'Post $id'},
  },
};

Map<String, dynamic> _countryIncoming({int id = 500}) => {
  '@type': 'message',
  'id': id,
  'chat_id': -10042,
  'is_outgoing': false,
  'content': {
    '@type': 'messageText',
    'text': {
      '@type': 'formattedText',
      'text': 'hello',
      'entities': <Map<String, dynamic>>[],
    },
  },
};

Map<String, dynamic> _firstContactActionBar(String country) => {
  '@type': 'chatActionBarReportAddBlock',
  'account_info': {
    '@type': 'accountInfo',
    'registration_month': 4,
    'registration_year': 2025,
    'phone_number_country_code': country,
  },
};

Future<CountryMessageFilter> _countryFilter() async {
  SharedPreferences.setMockInitialValues({
    'countryMessageFilter.selectedCountries': ['JP'],
    'countryMessageFilter.exemptCommonPrivateGroup': false,
    'countryMessageFilter.exemptThreeCommonGroups': false,
    'countryMessageFilter.exemptPlainText': false,
    'countryMessageFilter.exemptNonDefaultAvatar': false,
  });
  final prefs = await SharedPreferences.getInstance();
  return CountryMessageFilter()..initialize(prefs);
}

/// Minimal [TdClient] stub: only the calls the topic controller makes on a
/// plain history load, everything else fails fast.
class _RecordingTdClient implements TdClient {
  _RecordingTdClient(this.requests);

  final List<Map<String, dynamic>> requests;

  @override
  Future<Map<String, dynamic>> query(
    Map<String, dynamic> request, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    requests.add(request);
    return switch (request['@type']) {
      'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Me'},
      _ => {
        '@type': 'messages',
        'messages': [_topicMessage(81)],
      },
    };
  }

  @override
  void send(Map<String, dynamic> request) => requests.add(request);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected: ${invocation.memberName}');
}
