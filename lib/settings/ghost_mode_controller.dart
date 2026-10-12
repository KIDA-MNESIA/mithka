//
//  ghost_mode_controller.dart
//
//  AyuGram-style ghost mode. Guards the app behind the compile-time
//  `allowTelegramTosViolations` flag: when the flag is absent or false the
//  controller stays permanently disabled, every query method returns the
//  "never block" answer, and nothing else in the app changes. Preferences are
//  persisted in SharedPreferences so they survive restarts of self-built
//  binaries.
//
//  Semantics mirror NagramXF's AyuGhostPreferences: a global switch plus a
//  per-chat three-state exception — `default` follows the global switch,
//  `forceBlock` always intercepts, `forceAllow` never intercepts.
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/build_flags.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';

/// Per-chat exception state. [defaultState] follows the global switch.
enum GhostChatException {
  defaultState(0),
  forceBlock(1),
  forceAllow(2);

  const GhostChatException(this.storedValue);

  final int storedValue;

  static GhostChatException fromStoredValue(int value) =>
      GhostChatException.values.firstWhere(
        (entry) => entry.storedValue == value,
        orElse: () => GhostChatException.defaultState,
      );
}

/// Decision for one interception dimension in one chat, already resolved
/// against the global switch and the chat's exception state.
enum GhostInterceptDecision {
  block,
  allow;

  bool get isBlock => this == GhostInterceptDecision.block;
}

class GhostModeController extends ChangeNotifier {
  GhostModeController._();

  static final GhostModeController shared = GhostModeController._();

  /// Compile-time availability. False outside opted-in self-built binaries;
  /// every UI entry and every interception path consults this first.
  static bool get isAvailable => allowTelegramTosViolations;

  static const _globalEnabledKey = 'ghost_mode.enabled';
  static const _blockReadReceiptsKey = 'ghost_mode.blockReadReceipts';
  static const _blockStoryReadsKey = 'ghost_mode.blockStoryReads';
  static const _blockTypingKey = 'ghost_mode.blockTyping';
  static const _hideOnlineKey = 'ghost_mode.hideOnline';
  static const _chatExceptionKeyPrefix = 'ghost_mode.chat.';

  // Dimensions default to blocking while ghost mode is on; toggling only a
  // dimension off therefore needs a first tap, not a first tap and a second.
  static const _defaultBlockReadReceipts = true;
  static const _defaultBlockStoryReads = true;
  static const _defaultBlockTyping = true;
  static const _defaultHideOnline = true;

  SharedPreferences? _prefs;
  StreamSubscription<Map<String, dynamic>>? _authSub;

  bool _globalEnabled = false;
  bool _blockReadReceipts = _defaultBlockReadReceipts;
  bool _blockStoryReads = _defaultBlockStoryReads;
  bool _blockTyping = _defaultBlockTyping;
  bool _hideOnline = _defaultHideOnline;
  final Map<int, GhostChatException> _chatExceptions = {};

  bool get globalEnabled => _globalEnabled && isAvailable;
  bool get blockReadReceipts => _blockReadReceipts;
  bool get blockStoryReads => _blockStoryReads;
  bool get blockTyping => _blockTyping;
  bool get hideOnline => _hideOnline;

  Map<int, GhostChatException> get chatExceptions =>
      Map<int, GhostChatException>.unmodifiable(_chatExceptions);

  GhostChatException exceptionFor(int chatId) =>
      _chatExceptions[chatId] ?? GhostChatException.defaultState;

  /// Loads the persisted state and subscribes to authorization-ready updates.
  /// Safe to call again (the desktop settings reload re-seeds shared stores).
  void initialize(SharedPreferences prefs) {
    _prefs = prefs;
    _globalEnabled = prefs.getBool(_globalEnabledKey) ?? false;
    _blockReadReceipts =
        prefs.getBool(_blockReadReceiptsKey) ?? _defaultBlockReadReceipts;
    _blockStoryReads =
        prefs.getBool(_blockStoryReadsKey) ?? _defaultBlockStoryReads;
    _blockTyping = prefs.getBool(_blockTypingKey) ?? _defaultBlockTyping;
    _hideOnline = prefs.getBool(_hideOnlineKey) ?? _defaultHideOnline;
    _chatExceptions.clear();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_chatExceptionKeyPrefix)) continue;
      final chatId = int.tryParse(
        key.substring(_chatExceptionKeyPrefix.length),
      );
      if (chatId == null) continue;
      _chatExceptions[chatId] = GhostChatException.fromStoredValue(
        prefs.getInt(key) ?? 0,
      );
    }
    unawaited(_authSub?.cancel());
    _authSub = null;
    if (!isAvailable) return;
    _authSub = TdClient.shared
        .updatesOf('updateAuthorizationState', allAccounts: true)
        .listen((update) {
          if (update.obj('authorization_state')?.type !=
              'authorizationStateReady') {
            return;
          }
          if (!shouldShareOnline()) return;
          final clientId = update.integer('@client_id');
          if (clientId == null) return;
          applyOnlineStatusToClient(false, clientId, TdClient.shared);
        });
    unawaited(applyOnlineStatus());
  }

  /// Resolves [chatId] against the global switch and its exception state.
  GhostInterceptDecision decisionFor(
    int chatId,
    bool dimensionEnabled, {
    required bool dimensionOwnsInterception,
  }) {
    if (!globalEnabled || !dimensionEnabled) {
      return GhostInterceptDecision.allow;
    }
    if (dimensionOwnsInterception) {
      // The dimension itself turned interception off (e.g. story playback
      // needs the read marker); only a force-block exception can still
      // intercept that chat.
      return exceptionFor(chatId) == GhostChatException.forceBlock
          ? GhostInterceptDecision.block
          : GhostInterceptDecision.allow;
    }
    return switch (exceptionFor(chatId)) {
      GhostChatException.forceBlock => GhostInterceptDecision.block,
      GhostChatException.forceAllow => GhostInterceptDecision.allow,
      GhostChatException.defaultState => GhostInterceptDecision.block,
    };
  }

  /// Read receipts (viewMessages/force_read): hide that the chat was opened.
  GhostInterceptDecision shouldBlockRead(int chatId) =>
      decisionFor(chatId, _blockReadReceipts, dimensionOwnsInterception: false);

  /// Typing (sendChatAction): hide that the user is composing.
  GhostInterceptDecision shouldBlockTyping(int chatId) =>
      decisionFor(chatId, _blockTyping, dimensionOwnsInterception: false);

  /// Story reads (openStory). Turning the dimension off means the user
  /// wants story seen markers to keep working, so interception then survives
  /// only through a per-chat force-block exception.
  GhostInterceptDecision shouldBlockStories(int chatId) =>
      decisionFor(chatId, true, dimensionOwnsInterception: !_blockStoryReads);

  /// Online status. A global dimension with no per-chat exception: TDLib's
  /// `online` option is per account, not per chat. `true` only while ghost
  /// mode is globally on and the dimension is enabled.
  bool shouldShareOnline() => globalEnabled && _hideOnline;

  Future<void> setGlobalEnabled(bool value) async {
    if (!isAvailable) value = false;
    if (_globalEnabled == value) return;
    _globalEnabled = value;
    await _prefs?.setBool(_globalEnabledKey, value);
    unawaited(applyOnlineStatus());
    notifyListeners();
  }

  Future<void> setBlockReadReceipts(bool value) async {
    if (_blockReadReceipts == value) return;
    _blockReadReceipts = value;
    await _prefs?.setBool(_blockReadReceiptsKey, value);
    notifyListeners();
  }

  Future<void> setBlockStoryReads(bool value) async {
    if (_blockStoryReads == value) return;
    _blockStoryReads = value;
    await _prefs?.setBool(_blockStoryReadsKey, value);
    notifyListeners();
  }

  Future<void> setBlockTyping(bool value) async {
    if (_blockTyping == value) return;
    _blockTyping = value;
    await _prefs?.setBool(_blockTypingKey, value);
    notifyListeners();
  }

  Future<void> setHideOnline(bool value) async {
    if (_hideOnline == value) return;
    _hideOnline = value;
    await _prefs?.setBool(_hideOnlineKey, value);
    unawaited(applyOnlineStatus());
    notifyListeners();
  }

  Future<void> setChatException(int chatId, GhostChatException state) async {
    if (state == GhostChatException.defaultState) {
      if (_chatExceptions.remove(chatId) == null) return;
      await _prefs?.remove('$_chatExceptionKeyPrefix$chatId');
      notifyListeners();
      return;
    }
    if (_chatExceptions[chatId] == state) return;
    _chatExceptions[chatId] = state;
    await _prefs?.setInt('$_chatExceptionKeyPrefix$chatId', state.storedValue);
    notifyListeners();
  }

  /// Pushes the TDLib `online` option to every registered account client.
  ///
  /// `online` is an account-scoped option, not a chat property, so no
  /// per-chat exception applies.
  Future<void> applyOnlineStatus({TdClient? client}) async {
    if (!isAvailable) return;
    final td = client ?? TdClient.shared;
    final online = !shouldShareOnline();
    for (final clientId in td.registeredClientIds.toList()) {
      applyOnlineStatusToClient(online, clientId, td);
    }
  }

  @visibleForTesting
  void applyOnlineStatusToClient(bool online, int clientId, TdClient client) {
    client.sendTo({
      '@type': 'setOption',
      'name': 'online',
      'value': {'@type': 'optionValueBoolean', 'value': online},
    }, clientId);
  }

  @override
  void dispose() {
    unawaited(_authSub?.cancel());
    _authSub = null;
    super.dispose();
  }
}
