//
//  Mirror for the messages this account received: deleted and edited ones
//  stay readable. Every observation runs against a store whose TDLib wiring
//  is replaced by a broadcast controller, so updates are injected directly.
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
  late MessageHistoryStore store;
  late int notifications;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mithka-history-test');
    updates = StreamController<Map<String, dynamic>>.broadcast();
    store = MessageHistoryStore.forTesting();
    store.fileDir = dir;
    store.updateSource = (_) => updates.stream;
    notifications = 0;
    store.addListener(() => notifications++);
  });

  tearDown(() async {
    store.dispose();
    await updates.close();
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

  Map<String, dynamic> persistedJson() {
    final file = File('${dir.path}/message-history.json');
    expect(file.existsSync(), isTrue, reason: 'mirror file was never written');
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  test('incoming messages mirror with sender, kind and text', () async {
    await start();
    emit('updateNewMessage', {'message': _message(11, 100)});
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
    emit('updateNewMessage', {'message': _message(11, 100, text: 'secret')});
    await pump();
    emit('updateDeleteMessages', {
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
      emit('updateDeleteMessages', {
        'chat_id': '99',
        'message_ids': ['100'],
        'is_permanent': true,
        'from_cache': false,
      });
      await pump();
      expect(store.entries, isEmpty);
      expect(notifications, 0);
    },
  );

  test(
    'an edited pair produces one history event and keeps the old text',
    () async {
      await start();
      emit('updateNewMessage', {'message': _message(11, 100, text: 'v1')});
      await pump();
      emit('updateMessageEdited', {
        'chat_id': '11',
        'message_id': 100,
        'edit_date': 1700000123,
        'reply_markup': null,
      });
      emit('updateMessageContent', {
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
    emit('updateNewMessage', {'message': _message(11, 100, text: 'v1')});
    await pump();
    emit('updateMessageContent', {
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
      emit('updateNewMessage', {'message': _message(11, 100, text: 'v1')});
      await pump();
      emit('updateDeleteMessages', {
        'chat_id': '11',
        'message_ids': ['100'],
        'is_permanent': true,
        'from_cache': false,
      });
      await pump();
      emit('updateNewMessage', {'message': _message(11, 100, text: 'v1')});
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
    emit('updateNewMessage', {'message': photo});
    await pump();

    final entry = store.entry(11, 100)!;
    expect(entry.text, 'sunset');
    expect(entry.kindKey, 'historyKindPhoto');
  });

  test('an excluded chat records nothing', () async {
    await start();
    store.excludeChat(11);
    await pump();

    emit('updateNewMessage', {'message': _message(11, 100)});
    await pump();

    expect(store.entries, isEmpty);
    expect(store.isChatExcluded(11), isTrue);
  });

  test('exclusions load from prefs', () async {
    SharedPreferences.setMockInitialValues({
      'messageHistory.excludedChats.v1': <String>['11', '22'],
    });
    store.initialize(await SharedPreferences.getInstance());
    expect(store.excludedChats, {11, 22});
  });

  test('excludeChat removes the chat’s kept copies', () async {
    await start();
    emit('updateNewMessage', {'message': _message(11, 100)});
    emit('updateNewMessage', {'message': _message(12, 200)});
    await pump();

    store.excludeChat(11);
    await store.persistNowForTesting();

    expect(store.entries.map((entry) => entry.chatId), [12]);
    expect((persistedJson()['entries'] as List), hasLength(1));
  });

  test('clearChat and clearAll empty the mirror and the file', () async {
    await start();
    emit('updateNewMessage', {'message': _message(11, 100)});
    emit('updateNewMessage', {'message': _message(11, 101)});
    emit('updateNewMessage', {'message': _message(12, 200)});
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
    emit('updateNewMessage', {'message': _message(11, 100, text: 'kept')});
    await pump();
    await store.persistNowForTesting();

    // A fresh instance must read what the first one wrote; the original is
    // left alive for tearDown to dispose.
    final revived = MessageHistoryStore.forTesting();
    revived.fileDir = dir;
    addTearDown(revived.dispose);
    await revived.ensureLoaded();
    expect(revived.entryCount, 1);
    expect(revived.entry(11, 100)!.text, 'kept');
  });

  test('the mirror is bounded by maxEntries, dropping the oldest', () async {
    await start();
    for (var i = 0; i < MessageHistoryStore.maxEntries + 20; i++) {
      emit('updateNewMessage', {'message': _message(11, i)});
    }
    await pump();

    expect(store.entryCount, MessageHistoryStore.maxEntries);
    // LinkedHashMap insertion order: the earliest messages were evicted.
    expect(store.entry(11, 0), isNull);
    expect(store.entry(11, MessageHistoryStore.maxEntries + 19), isNotNull);
  });

  test('chats with kept copies feed entriesFor', () async {
    await start();
    emit('updateNewMessage', {'message': _message(11, 100)});
    emit('updateNewMessage', {'message': _message(11, 101)});
    emit('updateNewMessage', {'message': _message(12, 200)});
    await pump();

    expect(store.entriesFor(11), hasLength(2));
    expect(store.entriesFor(12), hasLength(1));
    expect(store.entriesFor(33), isEmpty);
  });
}
