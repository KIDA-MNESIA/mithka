//
//  message_history_store.dart
//
//  AyuGram-style local message history: every incoming message is mirrored
//  into a small on-device store so messages the counterpart deletes or edits
//  stay readable afterwards. Nothing here talks to Telegram — the mirror is
//  written from TDLib updates the account already received, and the kept
//  copies never leave this device.
//
//  Every record is owned by the account that received it: TDLib stamps each
//  update with '@client_id', the store resolves that to the account's user id
//  (getMe, cached) and keys entries, pending edit dates and exclusions by it.
//  Two accounts that see the same chat/message ids therefore keep two
//  separate records, and the viewer only ever shows the active account's.
//
//  The whole feature is a Telegram API Terms section 1.4 exception, so every
//  entry point — the TDLib subscription, the persisted file, the preference
//  keys, the settings row and the viewer route — is guarded by the
//  compile-time [allowTelegramTosViolations] constant. With the flag omitted
//  or false, no update is subscribed, no file or preference is read or
//  written, and every method is a no-op, so pre-existing saved state can
//  never take effect either.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/build_flags.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';

/// What the counterpart did to a mirrored message.
enum MessageHistoryState {
  /// The message still exists in the chat.
  active,

  /// The counterpart deleted the message; the copy is kept here only.
  deleted,
}

@immutable
class MessageHistoryEvent {
  const MessageHistoryEvent({
    required this.at,
    required this.oldText,
    required this.newText,
    this.editDate = 0,
  });

  /// Unix seconds at which mithka observed the change.
  final int at;

  /// Text before the change, or null when unknown (e.g. the mirror was
  /// populated by an older build).
  final String? oldText;

  /// Text after the change.
  final String newText;

  /// TDLib's edit_date for the edit that caused the event, 0 if unknown.
  final int editDate;

  Map<String, Object?> toJson() => {
    'at': at,
    'old': oldText,
    'new': newText,
    'editDate': editDate,
  };

  static MessageHistoryEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final newText = json['new'];
    if (at is! int || newText is! String) return null;
    final oldText = json['old'];
    final editDate = json['editDate'];
    return MessageHistoryEvent(
      at: at,
      oldText: oldText is String ? oldText : null,
      newText: newText,
      editDate: editDate is int ? editDate : 0,
    );
  }
}

@immutable
class MessageHistoryEntry {
  const MessageHistoryEntry({
    required this.accountUserId,
    required this.chatId,
    required this.messageId,
    required this.senderId,
    required this.date,
    required this.text,
    required this.kindKey,
    required this.state,
    required this.deletedAt,
    required this.events,
  });

  /// User id of the account that received the message. Two accounts that see
  /// the same chat/message ids keep two separate records.
  final int accountUserId;

  final int chatId;
  final int messageId;

  /// A user id (positive) or, when the chat itself posted, that chat's id
  /// (negative). Display names are resolved on view, never stored.
  final int senderId;

  /// Unix seconds the message was originally sent.
  final int date;

  /// Latest known text, or the caption for media messages. Empty for media
  /// without a caption — [kindKey] then names the content.
  final String text;

  /// [AppStringKeys] suffix of the content kind, e.g. `historyKindPhoto`.
  /// Empty for a plain text message.
  final String kindKey;

  final MessageHistoryState state;

  /// Unix seconds at which the deletion was observed, 0 while active.
  final int deletedAt;

  /// Content changes in observation order (oldest first).
  final List<MessageHistoryEvent> events;

  bool get isEdited => events.isNotEmpty;

  String get key => '$accountUserId:$chatId:$messageId';

  @override
  bool operator ==(Object other) =>
      other is MessageHistoryEntry &&
      other.accountUserId == accountUserId &&
      other.chatId == chatId &&
      other.messageId == messageId &&
      other.senderId == senderId &&
      other.date == date &&
      other.text == text &&
      other.kindKey == kindKey &&
      other.state == state &&
      other.deletedAt == deletedAt &&
      listEquals(other.events, events);

  @override
  int get hashCode => Object.hash(
    accountUserId,
    chatId,
    messageId,
    senderId,
    date,
    text,
    kindKey,
    state,
    deletedAt,
    Object.hashAll(events),
  );

  MessageHistoryEntry copyWith({
    int? accountUserId,
    String? text,
    String? kindKey,
    int? senderId,
    MessageHistoryState? state,
    int? deletedAt,
    List<MessageHistoryEvent>? events,
  }) => MessageHistoryEntry(
    accountUserId: accountUserId ?? this.accountUserId,
    chatId: chatId,
    messageId: messageId,
    senderId: senderId ?? this.senderId,
    date: date,
    text: text ?? this.text,
    kindKey: kindKey ?? this.kindKey,
    state: state ?? this.state,
    deletedAt: deletedAt ?? this.deletedAt,
    events: events ?? this.events,
  );

  Map<String, Object?> toJson() => {
    'account': accountUserId,
    'chat': chatId,
    'id': messageId,
    'sender': senderId,
    'date': date,
    'text': text,
    'kind': kindKey,
    'state': state.name,
    'deletedAt': deletedAt,
    'events': [for (final event in events) event.toJson()],
  };

  /// Entries without an 'account' field (mirror files from before the
  /// account identity existed) are dropped on load: an entry whose owning
  /// account is unknown must never be attributed to whichever account
  /// happens to be active.
  static MessageHistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final account = json['account'];
    final chat = json['chat'];
    final id = json['id'];
    final date = json['date'];
    final text = json['text'];
    if (account is! int ||
        chat is! int ||
        id is! int ||
        date is! int ||
        text is! String) {
      return null;
    }
    final sender = json['sender'];
    final kind = json['kind'];
    final state = json['state'];
    final deletedAt = json['deletedAt'];
    final events = json['events'];
    return MessageHistoryEntry(
      accountUserId: account,
      chatId: chat,
      messageId: id,
      senderId: sender is int ? sender : 0,
      date: date,
      text: text,
      kindKey: kind is String ? kind : '',
      state: state == 'deleted'
          ? MessageHistoryState.deleted
          : MessageHistoryState.active,
      deletedAt: deletedAt is int ? deletedAt : 0,
      events: events is List
          ? events
                .map(MessageHistoryEvent.fromJson)
                .whereType<MessageHistoryEvent>()
                .toList()
          : const [],
    );
  }
}

/// Resolves a TDLib client id to the owning account's user id. Production
/// asks the client itself (getMe) and caches; tests inject the mapping.
abstract class TosAccountUserIdResolver {
  Future<int?> resolve(int clientId);

  /// getMe through the exact client that produced the update. A client that
  /// is gone (slot removed, shutting down) resolves to null, and updates
  /// from it are dropped rather than misattributed.
  static final TosAccountUserIdResolver production = _TdClientUserIdResolver();
}

class _TdClientUserIdResolver implements TosAccountUserIdResolver {
  final Map<int, int> _cache = {};

  @override
  Future<int?> resolve(int clientId) async {
    final cached = _cache[clientId];
    if (cached != null) return cached;
    try {
      final me = await TdClient.shared.queryTo({'@type': 'getMe'}, clientId);
      final userId = me.int64('id');
      if (userId == null) return null;
      _cache[clientId] = userId;
      return userId;
    } catch (_) {
      return null;
    }
  }
}

/// Owns the mirrored message history: records TDLib updates, keeps the
/// entries in memory and persists a bounded batch to one JSON file.
class MessageHistoryStore extends ChangeNotifier {
  MessageHistoryStore._();

  static final MessageHistoryStore shared = MessageHistoryStore._();

  @visibleForTesting
  factory MessageHistoryStore.forTesting() = MessageHistoryStore._;

  static const _prefsKeyPrefix = 'messageHistory.excludedChats.v2.';
  static const _fileName = 'message-history.json';
  static const _tmpSuffix = '.tmp';

  /// Bounded on purpose: the mirror is a safety net for recent surprises,
  /// not an archival copy of the account.
  static const maxEntries = 5000;
  static const persistBatch = 400;

  static const observedUpdateTypes = [
    'updateNewMessage',
    'updateMessageEdited',
    'updateMessageContent',
    'updateDeleteMessages',
  ];

  final Map<String, MessageHistoryEntry> _byKey = {};

  /// Excluded chats per owning account; the read/write APIs operate on the
  /// active account's set.
  final Map<int, Set<int>> _excludedChatsByAccount = {};

  /// Pending updateMessageEdited dates, keyed per account. An edit or
  /// deletion observed on one account can never touch another account's
  /// entry even when the chat/message ids are identical.
  final Map<String, int> _pendingEditDates = {};

  /// Per-account update ordering: every account's updates are handled one
  /// after another, so a burst of edits and deletions cannot interleave.
  final Map<int, Future<void>> _accountWorkers = {};

  /// Resolved user id of the active client, kept in sync with
  /// [TosAccountUserIdResolver] results; null while unresolved.
  int? _activeAccountUserId;
  int? _activeAccountUserIdSource;

  /// Injected per-account id mapping (tests); defaults to getMe per client.
  @visibleForTesting
  TosAccountUserIdResolver? accountUserIdResolver;

  /// The active TDLib client id (tests); defaults to the shared client.
  @visibleForTesting
  int Function()? activeClientIdProvider;

  /// The active-slot change stream (tests); defaults to the shared client.
  @visibleForTesting
  Stream<int> Function()? activeSlotChangeSource;

  SharedPreferences? _prefs;
  bool _loaded = false;
  bool _observing = false;
  StreamSubscription<Map<String, dynamic>>? _tdSub;
  StreamSubscription<int>? _activeSlotSub;
  Timer? _persistTimer;
  bool _persisting = false;
  bool _dirtyWhilePersisting = false;

  /// Directory holding the mirror file. Resolved lazily; tests inject one.
  Directory? fileDir;

  TosAccountUserIdResolver get _resolver =>
      accountUserIdResolver ?? TosAccountUserIdResolver.production;

  int? get _currentClientId {
    final provider = activeClientIdProvider;
    if (provider != null) {
      final clientId = provider();
      return clientId == 0 ? null : clientId;
    }
    final clientId = TdClient.shared.activeClientId;
    return clientId == 0 ? null : clientId;
  }

  /// User id of the active account once resolved; null before that.
  int? get activeAccountUserId => _activeAccountUserId;

  /// Every kept copy of the ACTIVE account, oldest first — the order the
  /// mirror saw the messages. Bounded by [maxEntries]; the viewer reverses
  /// for display. Records of other accounts are never surfaced here.
  List<MessageHistoryEntry> get entries => List.unmodifiable(
    _byKey.values.where((entry) => entry.accountUserId == _activeAccountUserId),
  );

  /// Newest first, one chat of the active account, excluded chats are hidden.
  List<MessageHistoryEntry> entriesFor(int chatId) => isChatExcluded(chatId)
      ? const []
      : List.unmodifiable(
          _byKey.values.where(
            (entry) =>
                entry.accountUserId == _activeAccountUserId &&
                entry.chatId == chatId,
          ),
        );

  /// Looks up an entry of the ACTIVE account.
  MessageHistoryEntry? entry(int chatId, int messageId) =>
      _activeAccountUserId == null
      ? null
      : _byKey['$_activeAccountUserId:$chatId:$messageId'];

  int get entryCount => _byKey.length;

  bool isChatExcluded(int chatId) =>
      _activeAccountUserId != null &&
      (_excludedChatsByAccount[_activeAccountUserId]?.contains(chatId) ??
          false);

  Set<int> get excludedChats => Set.unmodifiable(
    _excludedChatsByAccount[_activeAccountUserId] ?? const {},
  );

  // ---------------------------------------------------------------------------
  // Bootstrap (guarded — with the flag off nothing below may run)
  // ---------------------------------------------------------------------------

  /// Reads the per-account exclusions of every account seen so far. Called
  /// from the app bootstrap with the shared prefs; a no-op unless the
  /// feature is compiled in. The pre-account v1 exclusion key is not
  /// migrated: an exclusion written before account identity existed cannot
  /// be attributed to an account without guessing.
  void initialize(SharedPreferences prefs) {
    if (!allowTelegramTosViolations) return;
    _prefs = prefs;
    _excludedChatsByAccount.clear();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_prefsKeyPrefix)) continue;
      final suffix = key.substring(_prefsKeyPrefix.length);
      final accountUserId = int.tryParse(suffix);
      if (accountUserId == null) continue;
      final raw = prefs.getStringList(key) ?? const <String>[];
      final excluded = raw.map(int.tryParse).whereType<int>().toSet();
      _excludedChatsByAccount[accountUserId] = excluded;
    }
    notifyListeners();
  }

  /// Subscribes the mirror to the TDLib updates it needs. Called once from
  /// the app bootstrap after [initialize].
  void startObserving() {
    if (!allowTelegramTosViolations) return;
    if (_observing) return;
    _observing = true;
    _tdSub = _openUpdates(observedUpdateTypes).listen(_onTdUpdate);
    _activeSlotSub = _openActiveSlotChanges().listen((_) {
      _refreshActiveAccount();
    });
    _refreshActiveAccount();
  }

  /// The typed update stream the mirror subscribes to. Tests replace this to
  /// drive updates without a TDLib client.
  @visibleForTesting
  Stream<Map<String, dynamic>> Function(Iterable<String> types)? updateSource;

  Stream<Map<String, dynamic>> _openUpdates(Iterable<String> types) {
    final source = updateSource;
    if (source != null) return source(types);
    return TdClient.shared.updatesOfAny(types);
  }

  Stream<int> _openActiveSlotChanges() {
    final source = activeSlotChangeSource;
    if (source != null) return source();
    return TdClient.shared.subscribeActiveSlotChanges();
  }

  /// Re-resolves the active account's user id when the active client
  /// changes; the viewer and the exclusion APIs read the cached result.
  void _refreshActiveAccount() {
    final clientId = _currentClientId;
    if (clientId == null) {
      _activeAccountUserId = null;
      _activeAccountUserIdSource = null;
      return;
    }
    if (_activeAccountUserIdSource == clientId &&
        _activeAccountUserId != null) {
      return;
    }
    _activeAccountUserIdSource = clientId;
    _activeAccountUserId = null;
    unawaited(
      _resolveAccountUserId(clientId).then((userId) {
        // A newer active client may have taken over while this one resolved.
        if (_currentClientId != clientId || userId == null) return;
        _activeAccountUserId = userId;
        notifyListeners();
      }),
    );
  }

  Future<int?> _resolveAccountUserId(int clientId) =>
      _resolver.resolve(clientId);

  @visibleForTesting
  @override
  void dispose() {
    _tdSub?.cancel();
    _tdSub = null;
    _activeSlotSub?.cancel();
    _activeSlotSub = null;
    _observing = false;
    _persistTimer?.cancel();
    _persistTimer = null;
    super.dispose();
  }

  /// Seeds the active account's identity for tests; stands in for what
  /// [_refreshActiveAccount] resolves from TDLib in production.
  @visibleForTesting
  void debugSetActiveAccount(int accountUserId) {
    if (!allowTelegramTosViolations) return;
    _activeAccountUserId = accountUserId;
    _activeAccountUserIdSource = null;
    notifyListeners();
  }

  /// Seeds in-memory copies for tests; never touches persistence. Guarded
  /// like every mutator: with the flag off the store stays empty no matter
  /// what reaches it.
  @visibleForTesting
  void debugSeed(List<MessageHistoryEntry> seeded) {
    if (!allowTelegramTosViolations) return;
    for (final entry in seeded) {
      _byKey[entry.key] = entry;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  void _onTdUpdate(Map<String, dynamic> update) {
    if (!allowTelegramTosViolations) return;
    // Every TDLib update is stamped with the client that received it
    // (updatesOfAny(allAccounts:true) documents this); resolving that to an
    // account user id is what keeps two accounts with identical chat/message
    // ids in two records. Updates without a client id are dropped: there is
    // no way to attribute them, and guessing the active account would
    // misattribute history whenever the active account changes.
    final clientId = update.integer('@client_id');
    if (clientId == null || clientId == 0) return;
    unawaited(_handleUpdateForClient(clientId, update));
  }

  /// Handles one update for [clientId], preserving per-account ordering:
  /// each account's updates run strictly one after another, while different
  /// accounts may resolve concurrently.
  Future<void> _handleUpdateForClient(
    int clientId,
    Map<String, dynamic> update,
  ) async {
    final userId = await _resolveAccountUserId(clientId);
    if (userId == null) return; // unattributable — never guess
    final previous = _accountWorkers[userId] ?? Future<void>.value();
    final worker = previous
        .catchError((_) {})
        .then((_) => _recordUpdate(userId, update));
    _accountWorkers[userId] = worker;
    try {
      await worker;
    } finally {
      // Removing the chain slot returns the worker future we already await.
      if (identical(_accountWorkers[userId], worker)) {
        unawaited(_accountWorkers.remove(userId));
      }
    }
  }

  Future<void> _recordUpdate(int accountUserId, Map<String, dynamic> update) {
    switch (update.type) {
      case 'updateNewMessage':
        _recordIncomingMessage(accountUserId, update.obj('message'));
      case 'updateMessageEdited':
        _rememberEditDate(accountUserId, update);
      case 'updateMessageContent':
        _recordContentUpdate(accountUserId, update);
      case 'updateDeleteMessages':
        _recordDeletedMessages(accountUserId, update);
    }
    return Future<void>.value();
  }

  /// Mirrors one incoming message. Also runs for messages that come back
  /// (cache eviction refetch, album resend): those refresh the copy but keep
  /// the recorded history, and a message deleted earlier becomes active
  /// again because it exists again.
  void recordIncomingMessage(Map<String, dynamic>? message) =>
      _recordIncomingMessage(_activeAccountUserId, message);

  void _recordIncomingMessage(
    int? accountUserId,
    Map<String, dynamic>? message,
  ) {
    if (!allowTelegramTosViolations) return;
    if (accountUserId == null || message == null) return;
    final chatId = message.int64('chat_id');
    // The message object carries its own id in `id` (message_id is the field
    // name on the update wrappers, not on message).
    final messageId = message.integer('id');
    if (chatId == null || messageId == null) return;
    if (_excludedChatsByAccount[accountUserId]?.contains(chatId) ?? false) {
      return;
    }

    final key = '$accountUserId:$chatId:$messageId';
    final existing = _byKey[key];
    if (existing != null) {
      final refreshed = existing.copyWith(
        text: _messageText(message) ?? existing.text,
        kindKey: _messageKindKey(message) ?? existing.kindKey,
        senderId: _senderId(message) ?? existing.senderId,
        state: MessageHistoryState.active,
        deletedAt: 0,
      );
      if (refreshed == existing) return;
      _byKey[key] = refreshed;
      notifyListeners();
      _schedulePersist();
      return;
    }

    final date = message.integer('date') ?? 0;
    final content = message.obj('content');
    _byKey[key] = MessageHistoryEntry(
      accountUserId: accountUserId,
      chatId: chatId,
      messageId: messageId,
      senderId: _senderId(message) ?? 0,
      date: date,
      text: _messageText(content) ?? '',
      kindKey: _messageKindKey(content) ?? '',
      state: MessageHistoryState.active,
      deletedAt: 0,
      events: const [],
    );
    _trim();
    notifyListeners();
    _schedulePersist();
  }

  /// updateMessageEdited carries the edit time but not the content; the new
  /// content arrives in a following updateMessageContent. Only that pair —
  /// not TDLib's own content generations (dice rolls, live locations) —
  /// produces an edit event. Pending dates are owned by the account whose
  /// client observed the edit.
  void _rememberEditDate(int accountUserId, Map<String, dynamic> update) {
    final chatId = update.int64('chat_id');
    final messageId = update.integer('message_id');
    if (chatId == null || messageId == null) return;
    _pendingEditDates['$accountUserId:$chatId:$messageId'] =
        update.integer('edit_date') ?? 0;
  }

  void _recordContentUpdate(int accountUserId, Map<String, dynamic> update) {
    final chatId = update.int64('chat_id');
    final messageId = update.integer('message_id');
    if (chatId == null || messageId == null) return;
    final key = '$accountUserId:$chatId:$messageId';
    final editDate = _pendingEditDates.remove(key);
    if (editDate == null) return;

    // Re-read after the await in [_handleUpdateForClient]: the mirror may
    // have loaded or changed since the update was received.
    final existing = _byKey[key];
    if (existing == null || existing.state == MessageHistoryState.deleted) {
      return;
    }
    final content = update.obj('new_content');
    final newText = _messageText(content) ?? '';
    final newKind = _messageKindKey(content) ?? '';
    if (newText == existing.text && newKind == existing.kindKey) return;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final event = MessageHistoryEvent(
      at: now,
      oldText: existing.text,
      newText: newText,
      editDate: editDate,
    );
    _byKey[key] = existing.copyWith(
      text: newText,
      kindKey: newKind,
      events: [...existing.events, event],
    );
    notifyListeners();
    _schedulePersist();
  }

  /// updateDeleteMessages marks known, still-active entries as deleted.
  /// TDLib sends it for permanent deletions and for messages that merely
  /// became inaccessible or were cache-evicted (`is_permanent: false`,
  /// `from_cache: true`); both belong in the mirror — the mirror's job is
  /// precisely to keep what the chat no longer shows. A message that really
  /// comes back re-activates through [recordIncomingMessage]. Deletions only
  /// ever touch the observing account's copy.
  void _recordDeletedMessages(int accountUserId, Map<String, dynamic> update) {
    final chatId = update.int64('chat_id');
    if (chatId == null) return;
    final ids = update.int64Array('message_ids') ?? const <int>[];
    if (ids.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var changed = false;
    for (final messageId in ids) {
      final key = '$accountUserId:$chatId:$messageId';
      final existing = _byKey[key];
      if (existing == null) continue;
      if (existing.state == MessageHistoryState.deleted) continue;
      _byKey[key] = existing.copyWith(
        state: MessageHistoryState.deleted,
        deletedAt: now,
      );
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    _schedulePersist();
  }

  // ---------------------------------------------------------------------------
  // Exclusions, clearing
  // ---------------------------------------------------------------------------

  /// Stops the ACTIVE account from recording [chatId] and drops its kept
  /// copies of that chat — an excluded chat must have no mirror at all, not
  /// just a paused one. Other accounts' copies of the same chat are kept.
  void excludeChat(int chatId) {
    if (!allowTelegramTosViolations) return;
    final accountUserId = _activeAccountUserId;
    if (accountUserId == null) return;
    final excluded = _excludedChatsByAccount.putIfAbsent(
      accountUserId,
      () => <int>{},
    );
    if (!excluded.add(chatId)) return;
    _byKey.removeWhere(
      (key, entry) =>
          entry.accountUserId == accountUserId && entry.chatId == chatId,
    );
    _persistExcludedChats(accountUserId);
    notifyListeners();
    _schedulePersist();
  }

  void includeChat(int chatId) {
    if (!allowTelegramTosViolations) return;
    final accountUserId = _activeAccountUserId;
    if (accountUserId == null) return;
    final excluded = _excludedChatsByAccount[accountUserId];
    if (excluded == null || !excluded.remove(chatId)) return;
    _persistExcludedChats(accountUserId);
    notifyListeners();
  }

  /// Removes the active account's kept copies of [chatId]; returns how many
  /// went away.
  int clearChat(int chatId) {
    if (!allowTelegramTosViolations) return 0;
    final accountUserId = _activeAccountUserId;
    if (accountUserId == null) return 0;
    final keys = [
      for (final entry in _byKey.values)
        if (entry.accountUserId == accountUserId && entry.chatId == chatId)
          entry.key,
    ];
    if (keys.isEmpty) return 0;
    for (final key in keys) {
      _byKey.remove(key);
    }
    notifyListeners();
    _schedulePersist();
    return keys.length;
  }

  /// Removes every kept copy of every account; returns how many went away.
  /// Deliberately global: "clear everything" must not leave invisible
  /// mirrors behind.
  int clearAll() {
    if (!allowTelegramTosViolations) return 0;
    if (_byKey.isEmpty) return 0;
    final removed = _byKey.length;
    _byKey.clear();
    notifyListeners();
    _schedulePersist();
    return removed;
  }

  /// Forgets an account entirely: its kept copies, its pending edit dates
  /// and its exclusion preference. Called when a slot is logged out or
  /// removed; account identity is known there, so nothing is guessed.
  void removeAccount(int accountUserId) {
    if (!allowTelegramTosViolations) return;
    var changed = false;
    final keys = [
      for (final entry in _byKey.values)
        if (entry.accountUserId == accountUserId) entry.key,
    ];
    for (final key in keys) {
      _byKey.remove(key);
    }
    if (keys.isNotEmpty) changed = true;
    _pendingEditDates.removeWhere(
      (key, _) => key.startsWith('$accountUserId:'),
    );
    if (_excludedChatsByAccount.remove(accountUserId) != null) changed = true;
    unawaited(_prefs?.remove('$_prefsKeyPrefix$accountUserId'));
    if (changed) {
      notifyListeners();
      _schedulePersist();
    }
  }

  void _persistExcludedChats(int accountUserId) {
    _prefs?.setStringList('$_prefsKeyPrefix$accountUserId', [
      for (final chatId
          in _excludedChatsByAccount[accountUserId] ?? const <int>{})
        '$chatId',
    ]);
  }

  // ---------------------------------------------------------------------------
  // Persistence — one JSON file for every account, batched, written
  // atomically via rename. Keys are account-scoped, so accounts share the
  // file without ever overwriting each other.
  // ---------------------------------------------------------------------------

  Future<void> ensureLoaded() async {
    if (!allowTelegramTosViolations) return;
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = fileDir ?? await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final raw = decoded['entries'];
      if (raw is! List) return;
      for (final json in raw) {
        final entry = MessageHistoryEntry.fromJson(json);
        if (entry == null) continue;
        _byKey.putIfAbsent(entry.key, () => entry);
      }
      _trim();
    } catch (_) {
      // A corrupt mirror must never break the app; start over on next write.
    }
    notifyListeners();
  }

  void _schedulePersist() {
    if (!allowTelegramTosViolations) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() async {
    if (_persisting) {
      _dirtyWhilePersisting = true;
      return;
    }
    _persisting = true;
    try {
      final dir = fileDir ?? await getApplicationSupportDirectory();
      final tmp = File('${dir.path}/$_fileName$_tmpSuffix');
      final batch = {
        'version': 2,
        'entries': [
          for (final entry in _byKey.values.take(persistBatch)) entry.toJson(),
        ],
      };
      await tmp.writeAsString(jsonEncode(batch), flush: true);
      await tmp.rename('${dir.path}/$_fileName');
    } catch (_) {
      return;
    } finally {
      _persisting = false;
    }
    if (_dirtyWhilePersisting) {
      _dirtyWhilePersisting = false;
      _schedulePersist();
    }
  }

  @visibleForTesting
  Future<void> persistNowForTesting() => _persistNow();

  void _trim() {
    while (_byKey.length > maxEntries) {
      _byKey.remove(_byKey.keys.first);
    }
  }

  // ---------------------------------------------------------------------------
  // Message field extraction
  // ---------------------------------------------------------------------------

  int? _senderId(Map<String, dynamic> message) {
    final sender = message.obj('sender_id');
    if (sender == null) return null;
    switch (sender.type) {
      case 'messageSenderUser':
        return sender.int64('user_id');
      case 'messageSenderChat':
        return sender.int64('chat_id');
    }
    return null;
  }

  /// Plain text of a [formattedText] object.
  static String? _formattedText(Map<String, dynamic>? formatted) =>
      formatted?.str('text');

  /// The message's text, or its caption for captioned media.
  static String? _messageText(Map<String, dynamic>? content) {
    if (content == null) return null;
    switch (content.type) {
      case 'messageText':
        return _formattedText(content.obj('text'));
      case 'messagePhoto':
      case 'messageVideo':
      case 'messageAnimation':
      case 'messageAudio':
      case 'messageDocument':
      case 'messageVoiceNote':
        return _formattedText(content.obj('caption')) ?? '';
    }
    return null;
  }

  /// Maps a TDLib content type onto the [AppStringKeys] suffix of a localized
  /// kind label; null for plain text. Stored as the bare suffix so the key
  /// names stay in one place (the viewer).
  static String? _messageKindKey(Map<String, dynamic>? content) {
    if (content == null) return null;
    switch (content.type) {
      case 'messagePhoto':
      case 'messageExpiredPhoto':
        return 'historyKindPhoto';
      case 'messageVideo':
      case 'messageExpiredVideo':
        return 'historyKindVideo';
      case 'messageVideoNote':
      case 'messageExpiredVideoNote':
        return 'historyKindVideoNote';
      case 'messageVoiceNote':
        return 'historyKindVoice';
      case 'messageAnimation':
        return 'historyKindAnimation';
      case 'messageSticker':
        return 'historyKindSticker';
      case 'messageDocument':
        return 'historyKindDocument';
      case 'messageAudio':
        return 'historyKindAudio';
      case 'messagePoll':
        return 'historyKindPoll';
      case 'messageLocation':
      case 'messageLiveLocation':
        return 'historyKindLocation';
      case 'messageContact':
        return 'historyKindContact';
      case 'messageDice':
        return 'historyKindDice';
    }
    return null;
  }
}
