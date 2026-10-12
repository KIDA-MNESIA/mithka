//
//  Mirror for the messages this account received: deleted and edited ones
//  stay readable. Every observation runs against a store whose TDLib wiring
//  is replaced by a broadcast controller, so updates are injected directly.
//
//  Records are owned by the account whose client produced the update:
//  injected updates carry '@client_id' (as every real TDLib update does) and
//  a stub resolver maps client ids to account user ids.
//
//  The suite needs the feature compiled in
//  (--dart-define=I_DONT_FUCKING_CARE_ABOUT_TOS=true); without it the store
//  is a no-op by design, so the whole file skips.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/config/build_flags.dart';
import 'package:mithka/history/message_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = allowTelegramTosViolations;

/// Client id used by the pre-account tests' updates; resolved to 7001.
const _clientA = 101;
const _accountA = 7001;
const _clientB = 202;
const _accountB = 7002;

/// Stub per-client identity mapping; a missing client resolves to null so
/// its updates are dropped instead of misattributed.
class _StubResolver implements TosAccountUserIdResolver {
  _StubResolver(this.ids);

  final Map<int, int?> ids;

  @override
  Future<int?> resolve(int clientId) async => ids[clientId];
}

Map<String, dynamic> _message(
  int chatId,
  int messageId, {
  String text = 'hello',
  int date = 1700000000,
  int senderId = 42,
}) => {
  '@type': 'message',
  'chat_id': '$chatId',
  'id': messageId,
  'date': date,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': '$senderId'},
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': text},
  },
};

void main() {
  if (!_enabled) {
    return;
  }

  late Directory dir;
  late StreamController<Map<String, dynamic>> updates;
  late StreamController<int> activeSlotChanges;
  late MessageHistoryStore store;
  late int notifications;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mithka-history-test');
    updates = StreamController<Map<String, dynamic>>.broadcast();
    activeSlotChanges = StreamController<int>.broadcast();
    store = MessageHistoryStore.forTesting();
    store.fileDir = dir;
    store.updateSource = (_) => updates.stream;
    store.activeSlotChangeSource = () => activeSlotChanges.stream;
    store.accountUserIdResolver = _StubResolver({
      _clientA: _accountA,
      _clientB: _accountB,
    });
    store.activeClientIdProvider = () => _clientA;
    SharedPreferences.setMockInitialValues(const {});
    store.initialize(await SharedPreferences.getInstance());
    notifications = 0;
    store.addListener(() => notifications++);
  });

  tearDown(() async {
    store.dispose();
    await updates.close();
    await activeSlotChanges.close();
    await dir.delete(recursive: true);
  });

  Future<void> pump() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> start() async {
    store.startObserving();
    await pump();
  }

  void emit(String type, Map<String, dynamic> update) =>
      updates.add({'@type': type, ...update});

  /// Emits an update stamped with the TDLib client that observed it, the
  /// way every real update arrives.
  void emitAs(int clientId, String type, Map<String, dynamic> update) =>
      updates.add({'@type': type, '@client_id': clientId, ...update});

  Map<String, dynamic> persistedJson() {
    final file = File('${dir.path}/message-history.json');
    expect(file.existsSync(), isTrue, reason: 'mirror file was never written');
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  test('incoming messages mirror with sender, kind and text', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 100)});
    await pump();
    await store.persistNowForTesting();

    final entries = store.entries;
    expect(entries, hasLength(1));
    expect(entries.single.chatId, 11);
    expect(entries.single.messageId, 100);
    expect(entries.single.senderId, 42);
    expect(entries.single.date, 1700000000);
    expect(entries.single.text, 'hello');
    expect(entries.single.kindKey, isEmpty);
    expect(entries.single.state, MessageHistoryState.active);
    expect(persistedJson()['entries'], hasLength(1));
  });

  test('updateDeleteMessages keeps the copy and marks it deleted', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'secret'),
    });
    await pump();
    emitAs(_clientA, 'updateDeleteMessages', {
      'chat_id': '11',
      'message_ids': ['100'],
      'is_permanent': true,
      'from_cache': false,
    });
    await pump();

    final entry = store.entry(11, 100);
    expect(entry, isNotNull);
    expect(entry!.state, MessageHistoryState.deleted);
    expect(entry.deletedAt, greaterThan(0));
    expect(entry.text, 'secret');

    await store.persistNowForTesting();
    final state = (persistedJson()['entries'] as List).single;
    expect(state['state'], 'deleted');
    expect(state['text'], 'secret');
  });

  test(
    'deletions for unknown chats and unknown messages are ignored',
    () async {
      await start();
      emitAs(_clientA, 'updateDeleteMessages', {
        'chat_id': '99',
        'message_ids': ['100'],
        'is_permanent': true,
        'from_cache': false,
      });
      await pump();
      // The active-client resolution during start() legitimately notifies.
      notifications = 0;
      expect(store.entries, isEmpty);
      expect(notifications, 0);
    },
  );

  test(
    'an edited pair produces one history event and keeps the old text',
    () async {
      await start();
      emitAs(_clientA, 'updateNewMessage', {
        'message': _message(11, 100, text: 'v1'),
      });
      await pump();
      emitAs(_clientA, 'updateMessageEdited', {
        'chat_id': '11',
        'message_id': 100,
        'edit_date': 1700000123,
        'reply_markup': null,
      });
      emitAs(_clientA, 'updateMessageContent', {
        'chat_id': '11',
        'message_id': 100,
        'new_content': {
          '@type': 'messageText',
          'text': {'@type': 'formattedText', 'text': 'v2'},
        },
      });
      await pump();

      final entry = store.entry(11, 100)!;
      expect(entry.isEdited, isTrue);
      expect(entry.text, 'v2');
      expect(entry.events, hasLength(1));
      expect(entry.events.single.oldText, 'v1');
      expect(entry.events.single.newText, 'v2');
      expect(entry.events.single.editDate, 1700000123);
      expect(notifications, greaterThan(0));
    },
  );

  test('content changes without a preceding edit produce nothing', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'v1'),
    });
    await pump();
    emitAs(_clientA, 'updateMessageContent', {
      'chat_id': '11',
      'message_id': 100,
      'new_content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': 'v2'},
      },
    });
    await pump();

    final entry = store.entry(11, 100)!;
    expect(entry.isEdited, isFalse);
    expect(entry.text, 'v1');
  });

  test(
    'a deleted message that comes back is active again, history intact',
    () async {
      await start();
      emitAs(_clientA, 'updateNewMessage', {
        'message': _message(11, 100, text: 'v1'),
      });
      await pump();
      emitAs(_clientA, 'updateDeleteMessages', {
        'chat_id': '11',
        'message_ids': ['100'],
        'is_permanent': true,
        'from_cache': false,
      });
      await pump();
      emitAs(_clientA, 'updateNewMessage', {
        'message': _message(11, 100, text: 'v1'),
      });
      await pump();

      final entry = store.entry(11, 100)!;
      expect(entry.state, MessageHistoryState.active);
      expect(entry.deletedAt, 0);
    },
  );

  test('media messages mirror their caption and kind', () async {
    await start();
    final photo = _message(11, 100)
      ..['content'] = {
        '@type': 'messagePhoto',
        'photo': {'@type': 'photo'},
        'caption': {'@type': 'formattedText', 'text': 'sunset'},
      };
    emitAs(_clientA, 'updateNewMessage', {'message': photo});
    await pump();

    final entry = store.entry(11, 100)!;
    expect(entry.text, 'sunset');
    expect(entry.kindKey, 'historyKindPhoto');
  });

  test('an excluded chat records nothing', () async {
    await start();
    store.excludeChat(11);
    await pump();

    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 100)});
    await pump();

    expect(store.entries, isEmpty);
    expect(store.isChatExcluded(11), isTrue);
  });

  test('exclusions load from the active account’s prefs key', () async {
    SharedPreferences.setMockInitialValues({
      'messageHistory.excludedChats.v2.$_accountA': <String>['11', '22'],
    });
    store.initialize(await SharedPreferences.getInstance());
    store.debugSetActiveAccount(_accountA);
    expect(store.excludedChats, {11, 22});
  });

  test('excludeChat removes the chat’s kept copies', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 100)});
    emitAs(_clientA, 'updateNewMessage', {'message': _message(12, 200)});
    await pump();

    store.excludeChat(11);
    await store.persistNowForTesting();

    expect(store.entries.map((entry) => entry.chatId), [12]);
    expect((persistedJson()['entries'] as List), hasLength(1));
  });

  test('clearChat and clearAll empty the mirror and the file', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 100)});
    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 101)});
    emitAs(_clientA, 'updateNewMessage', {'message': _message(12, 200)});
    await pump();

    expect(store.clearChat(11), 2);
    expect(store.entryCount, 1);
    expect(store.clearChat(11), 0);
    expect(store.clearAll(), 1);
    expect(store.entryCount, 0);

    await store.persistNowForTesting();
    expect((persistedJson()['entries'] as List), isEmpty);
  });

  test('persisted copies load back', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'kept'),
    });
    await pump();
    await store.persistNowForTesting();

    // A fresh instance must read what the first one wrote; the original is
    // left alive for tearDown to dispose.
    final revived = MessageHistoryStore.forTesting();
    revived.fileDir = dir;
    addTearDown(revived.dispose);
    await revived.ensureLoaded();
    expect(revived.entryCount, 1);
    revived.debugSetActiveAccount(_accountA);
    expect(revived.entry(11, 100)!.text, 'kept');
  });

  test('the mirror is bounded by maxEntries, dropping the oldest', () async {
    await start();
    for (var i = 0; i < MessageHistoryStore.maxEntries + 20; i++) {
      emitAs(_clientA, 'updateNewMessage', {'message': _message(11, i)});
    }
    await pump();

    expect(store.entryCount, MessageHistoryStore.maxEntries);
    // LinkedHashMap insertion order: the earliest messages were evicted.
    expect(store.entry(11, 0), isNull);
    expect(store.entry(11, MessageHistoryStore.maxEntries + 19), isNotNull);
  });

  test('chats with kept copies feed entriesFor', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 100)});
    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 101)});
    emitAs(_clientA, 'updateNewMessage', {'message': _message(12, 200)});
    await pump();

    expect(store.entriesFor(11), hasLength(2));
    expect(store.entriesFor(12), hasLength(1));
    expect(store.entriesFor(33), isEmpty);
  });

  // ---------------------------------------------------------------------------
  // Account ownership
  // ---------------------------------------------------------------------------

  test(
    'two accounts with the same chat/message ids keep two records',
    () async {
      await start();
      emitAs(_clientA, 'updateNewMessage', {
        'message': _message(11, 100, text: 'from A'),
      });
      await pump();
      emitAs(_clientB, 'updateNewMessage', {
        'message': _message(11, 100, text: 'from B'),
      });
      await pump();

      expect(store.entryCount, 2);
      // entryCount is global; entries is scoped to the active account, so
      // read the keys off entryCount-verified entries from both scopes.
      store.debugSetActiveAccount(_accountB);
      expect(store.entries.map((entry) => entry.key), ['$_accountB:11:100']);
      store.debugSetActiveAccount(_accountA);
      expect(store.entries.map((entry) => entry.key), ['$_accountA:11:100']);

      // The viewer only ever sees the active account's copy.
      expect(store.activeAccountUserId, _accountA);
      expect(store.entriesFor(11).single.text, 'from A');
      expect(store.entriesFor(11).single.accountUserId, _accountA);

      store.debugSetActiveAccount(_accountB);
      expect(store.entriesFor(11).single.text, 'from B');
      expect(store.entriesFor(11).single.accountUserId, _accountB);
      expect(store.entry(11, 100)!.text, 'from B');
    },
  );

  test('a switch of the active client re-scopes the mirror', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'from A'),
    });
    await pump();
    expect(store.activeAccountUserId, _accountA);

    store.activeClientIdProvider = () => _clientB;
    activeSlotChanges.add(_clientB);
    await pump();
    expect(store.activeAccountUserId, _accountB);
    expect(store.entriesFor(11), isEmpty);
  });

  test(
    'edits from one account never touch the other account’s entry',
    () async {
      await start();
      emitAs(_clientA, 'updateNewMessage', {
        'message': _message(11, 100, text: 'from A'),
      });
      emitAs(_clientB, 'updateNewMessage', {
        'message': _message(11, 100, text: 'from B'),
      });
      await pump();

      // Account B's counterpart edits; A's copy must stay untouched.
      emitAs(_clientB, 'updateMessageEdited', {
        'chat_id': '11',
        'message_id': 100,
        'edit_date': 1700000123,
      });
      emitAs(_clientB, 'updateMessageContent', {
        'chat_id': '11',
        'message_id': 100,
        'new_content': {
          '@type': 'messageText',
          'text': {'@type': 'formattedText', 'text': 'edited B'},
        },
      });
      await pump();

      store.debugSetActiveAccount(_accountA);
      final a = store.entry(11, 100)!;
      expect(a.isEdited, isFalse);
      expect(a.text, 'from A');
      expect(a.events, isEmpty);

      store.debugSetActiveAccount(_accountB);
      final b = store.entry(11, 100)!;
      expect(b.isEdited, isTrue);
      expect(b.text, 'edited B');
      expect(b.events.single.editDate, 1700000123);

      // And the other way around.
      emitAs(_clientA, 'updateMessageEdited', {
        'chat_id': '11',
        'message_id': 100,
        'edit_date': 1700000456,
      });
      emitAs(_clientA, 'updateMessageContent', {
        'chat_id': '11',
        'message_id': 100,
        'new_content': {
          '@type': 'messageText',
          'text': {'@type': 'formattedText', 'text': 'edited A'},
        },
      });
      await pump();

      store.debugSetActiveAccount(_accountB);
      expect(store.entry(11, 100)!.text, 'edited B');
      store.debugSetActiveAccount(_accountA);
      final a2 = store.entry(11, 100)!;
      expect(a2.text, 'edited A');
      expect(a2.events, hasLength(1));
      expect(a2.events.single.editDate, 1700000456);
    },
  );

  test('deletions from one account mark only that account’s copy', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'from A'),
    });
    emitAs(_clientB, 'updateNewMessage', {
      'message': _message(11, 100, text: 'from B'),
    });
    await pump();

    emitAs(_clientB, 'updateDeleteMessages', {
      'chat_id': '11',
      'message_ids': ['100'],
      'is_permanent': true,
      'from_cache': false,
    });
    await pump();

    store.debugSetActiveAccount(_accountA);
    expect(store.entry(11, 100)!.state, MessageHistoryState.active);
    expect(store.entry(11, 100)!.deletedAt, 0);

    store.debugSetActiveAccount(_accountB);
    expect(store.entry(11, 100)!.state, MessageHistoryState.deleted);
    expect(store.entry(11, 100)!.deletedAt, greaterThan(0));
  });

  test('exclusions are per account and the same chat stays recorded '
      'elsewhere', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'from A'),
    });
    emitAs(_clientB, 'updateNewMessage', {
      'message': _message(11, 100, text: 'from B'),
    });
    await pump();

    // Account A excludes the chat: its copies are dropped, B's are kept.
    store.debugSetActiveAccount(_accountA);
    store.excludeChat(11);
    await pump();

    expect(store.isChatExcluded(11), isTrue);
    expect(store.entriesFor(11), isEmpty);
    store.debugSetActiveAccount(_accountB);
    expect(store.isChatExcluded(11), isFalse);
    expect(store.entriesFor(11).single.text, 'from B');

    // A no longer records the chat; B still does.
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 101, text: 'from A again'),
    });
    emitAs(_clientB, 'updateNewMessage', {
      'message': _message(11, 102, text: 'from B again'),
    });
    await pump();
    store.debugSetActiveAccount(_accountA);
    expect(store.entriesFor(11), isEmpty);
    store.debugSetActiveAccount(_accountB);
    expect(store.entriesFor(11).map((entry) => entry.messageId), [100, 102]);

    // Each account's exclusion persists under its own prefs key.
    store.debugSetActiveAccount(_accountB);
    store.excludeChat(33);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('messageHistory.excludedChats.v2.$_accountA'), [
      '11',
    ]);
    expect(prefs.getStringList('messageHistory.excludedChats.v2.$_accountB'), [
      '33',
    ]);
  });

  test(
    'persisted records carry their account and reload per account',
    () async {
      await start();
      emitAs(_clientA, 'updateNewMessage', {
        'message': _message(11, 100, text: 'from A'),
      });
      emitAs(_clientB, 'updateNewMessage', {
        'message': _message(11, 100, text: 'from B'),
      });
      await pump();
      await store.persistNowForTesting();

      final json = persistedJson();
      expect(json['version'], 2);
      final entries = json['entries'] as List;
      expect(entries, hasLength(2));
      expect(entries.map((entry) => entry['account']).toSet(), {
        _accountA,
        _accountB,
      });

      final revived = MessageHistoryStore.forTesting();
      revived.fileDir = dir;
      addTearDown(revived.dispose);
      await revived.ensureLoaded();
      expect(revived.entryCount, 2);

      revived.debugSetActiveAccount(_accountA);
      expect(revived.entry(11, 100)!.text, 'from A');
      revived.debugSetActiveAccount(_accountB);
      expect(revived.entry(11, 100)!.text, 'from B');
    },
  );

  test('a pre-account mirror file loads to zero entries', () async {
    // v1 records have no account field; loading them would attribute the
    // history to whichever account happens to be active, so they are
    // dropped on purpose.
    File('${dir.path}/message-history.json').writeAsStringSync(
      '{"version":1,"entries":[{"chat":11,"id":100,"sender":42,'
      '"date":1700000000,"text":"stale","kind":"","state":"active",'
      '"deletedAt":0,"events":[]}]}',
    );
    final revived = MessageHistoryStore.forTesting();
    revived.fileDir = dir;
    addTearDown(revived.dispose);
    await revived.ensureLoaded();
    expect(revived.entryCount, 0);
    expect(revived.entries, isEmpty);
  });

  test('removeAccount forgets that account and keeps the others', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {'message': _message(12, 200)});
    emitAs(_clientB, 'updateNewMessage', {'message': _message(11, 100)});
    emitAs(_clientB, 'updateMessageEdited', {
      'chat_id': '11',
      'message_id': 100,
      'edit_date': 1700000123,
    });
    await pump();

    store.debugSetActiveAccount(_accountA);
    store.excludeChat(22);
    store.debugSetActiveAccount(_accountB);
    store.excludeChat(33);
    await pump();

    store.removeAccount(_accountB);

    expect(store.entryCount, 1);
    store.debugSetActiveAccount(_accountA);
    expect(store.entries.single.chatId, 12);
    store.debugSetActiveAccount(_accountB);
    expect(store.entries, isEmpty);
    expect(store.isChatExcluded(33), isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.containsKey('messageHistory.excludedChats.v2.$_accountB'),
      isFalse,
    );
    expect(prefs.getStringList('messageHistory.excludedChats.v2.$_accountA'), [
      '22',
    ]);

    // B's pending edit dates died with the account: a late content update
    // produces nothing instead of touching a re-registered account's copy.
    emitAs(_clientB, 'updateNewMessage', {
      'message': _message(11, 100, text: 'fresh'),
    });
    await pump();
    emitAs(_clientB, 'updateMessageContent', {
      'chat_id': '11',
      'message_id': 100,
      'new_content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': 'orphan edit'},
      },
    });
    await pump();
    store.debugSetActiveAccount(_accountB);
    final entry = store.entry(11, 100)!;
    expect(entry.text, 'fresh');
    expect(entry.isEdited, isFalse);
  });

  test('updates whose client cannot be resolved are dropped', () async {
    store.accountUserIdResolver = _StubResolver({
      _clientA: _accountA,
      777: null,
    });
    await start();
    // The active-client resolution during start() legitimately notifies.
    notifications = 0;
    emitAs(777, 'updateNewMessage', {'message': _message(11, 100)});
    await pump();
    expect(store.entryCount, 0);
    expect(store.entries, isEmpty);
    expect(notifications, 0);

    // A later resolvable account still records; the failure is per client.
    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 100)});
    await pump();
    expect(store.entryCount, 1);
  });

  test('updates without a client id are dropped, not attributed', () async {
    await start();
    // The active-client resolution during start() legitimately notifies.
    notifications = 0;
    emit('updateNewMessage', {'message': _message(11, 100)});
    await pump();
    expect(store.entryCount, 0);
    expect(notifications, 0);
  });

  test('a burst of edits on one account lands in arrival order', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'v0'),
    });
    emitAs(_clientB, 'updateNewMessage', {
      'message': _message(11, 100, text: 'other account'),
    });
    emitAs(_clientA, 'updateMessageEdited', {
      'chat_id': '11',
      'message_id': 100,
      'edit_date': 111,
    });
    emitAs(_clientA, 'updateMessageContent', {
      'chat_id': '11',
      'message_id': 100,
      'new_content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': 'v1'},
      },
    });
    emitAs(_clientA, 'updateMessageEdited', {
      'chat_id': '11',
      'message_id': 100,
      'edit_date': 222,
    });
    emitAs(_clientA, 'updateMessageContent', {
      'chat_id': '11',
      'message_id': 100,
      'new_content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': 'v2'},
      },
    });
    await pump();

    store.debugSetActiveAccount(_accountA);
    final entry = store.entry(11, 100)!;
    expect(entry.text, 'v2');
    expect(entry.events.map((event) => event.editDate), [111, 222]);
    expect(entry.events[0].newText, 'v1');
    expect(entry.events[1].newText, 'v2');
  });
}
