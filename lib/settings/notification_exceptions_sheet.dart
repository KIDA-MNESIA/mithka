//
//  notification_exceptions_sheet.dart
//
//  The chats that override one notification scope: what each override changes,
//  a way to open the chat, and a way to hand it back to the scope. TDLib keeps
//  no delete method for an exception, so resetting writes a
//  chatNotificationSettings whose every use_default_* flag is set.
//

import 'dart:async';

import 'package:flutter/material.dart';

import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/photo_avatar.dart';
import '../components/toast.dart';
import '../components/ui_components.dart';
import '../l10n/app_localizations.dart';
import '../notifications/notification_settings_payload.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';

/// Scope key for story notifications, which TDLib tracks outside the three
/// chat scopes.
const storiesNotificationScope = 'stories';

String notificationExceptionCountLabel(int count) => AppStrings.t(
  count == 1
      ? AppStringKeys.notificationException
      : AppStringKeys.notificationExceptions,
  {'value1': count},
);

/// A `chatNotificationSettings` that inherits everything again.
///
/// Every `use_default_*` flag is true, which is what makes TDLib drop the
/// per-chat exception. The values are still sent in full because the object
/// has required fields; TDLib ignores each one while its flag is set.
Map<String, dynamic> resetChatNotificationSettingsPayload() => {
  ...inheritedChatNotificationSettings(muteFor: 0, useDefaultMuteFor: true),
  'sound_id': 0,
  'show_preview': true,
  'mute_stories': false,
  'story_sound_id': 0,
  'show_story_poster': true,
  'disable_pinned_message_notifications': false,
  'disable_mention_notifications': false,
};

/// The short labels describing how a chat departs from its scope.
///
/// Only explicit overrides count: a flag left on its default cannot differ.
/// Directional wording follows the value the chat actually holds, so "Muted"
/// never appears for a chat that merely inherits a muted scope.
List<String> notificationExceptionDeviations({
  required Map<String, dynamic>? chatSettings,
  required Map<String, dynamic>? scopeSettings,
  required bool stories,
}) {
  if (chatSettings == null) return const [];
  final labels = <String>[];
  if (stories) {
    if (!(chatSettings.boolean('use_default_mute_stories') ?? true)) {
      labels.add(
        AppStrings.t(
          chatSettings.boolean('mute_stories') ?? false
              ? AppStringKeys.notificationExceptionStoriesMuted
              : AppStringKeys.notificationExceptionStoriesOn,
        ),
      );
    }
    if (!(chatSettings.boolean('use_default_story_sound') ?? true)) {
      labels.add(
        AppStrings.t(
          _soundId(chatSettings, 'story_sound_id') == 0
              ? AppStringKeys.notificationExceptionStorySoundOff
              : AppStringKeys.notificationExceptionStoryCustomSound,
        ),
      );
    }
    if (!(chatSettings.boolean('use_default_show_story_poster') ?? true) &&
        !(chatSettings.boolean('show_story_poster') ??
            chatSettings.boolean('show_story_sender') ??
            true)) {
      labels.add(
        AppStrings.t(AppStringKeys.notificationExceptionStoryPosterHidden),
      );
    }
    return labels;
  }

  final scopeMuted = (scopeSettings?.integer('mute_for') ?? 0) > 0;
  if (!(chatSettings.boolean('use_default_mute_for') ?? true) &&
      ((chatSettings.integer('mute_for') ?? 0) > 0) != scopeMuted) {
    labels.add(
      AppStrings.t(
        scopeMuted
            ? AppStringKeys.notificationExceptionUnmuted
            : AppStringKeys.notificationExceptionMuted,
      ),
    );
  }

  if (!(chatSettings.boolean('use_default_sound') ?? true) &&
      _soundId(chatSettings, 'sound_id') !=
          _soundId(scopeSettings, 'sound_id')) {
    labels.add(
      AppStrings.t(
        _soundId(chatSettings, 'sound_id') == 0
            ? AppStringKeys.notificationExceptionSoundOff
            : AppStringKeys.notificationExceptionCustomSound,
      ),
    );
  }

  final chatPreview = chatSettings.boolean('show_preview') ?? true;
  if (!(chatSettings.boolean('use_default_show_preview') ?? true) &&
      chatPreview != (scopeSettings?.boolean('show_preview') ?? true)) {
    labels.add(
      AppStrings.t(
        chatPreview
            ? AppStringKeys.notificationExceptionPreviewOn
            : AppStringKeys.notificationExceptionPreviewOff,
      ),
    );
  }

  if (!(chatSettings.boolean('use_default_disable_mention_notifications') ??
          true) &&
      (chatSettings.boolean('disable_mention_notifications') ?? false)) {
    labels.add(AppStrings.t(AppStringKeys.notificationExceptionMentionsOff));
  }

  if (!(chatSettings.boolean(
            'use_default_disable_pinned_message_notifications',
          ) ??
          true) &&
      (chatSettings.boolean('disable_pinned_message_notifications') ?? false)) {
    labels.add(AppStrings.t(AppStringKeys.notificationExceptionPinnedOff));
  }
  return labels;
}

int _soundId(Map<String, dynamic>? settings, String key) {
  final value = settings?.int64(key) ?? 0;
  return value > 0 ? value : 0;
}

/// The concrete TDLib client a notification-exception sheet is bound to.
///
/// Chat ids and the exception list itself are account-scoped, so a sheet that
/// outlives a switch must keep using the account it was opened for instead of
/// following the foreground.
abstract interface class NotificationExceptionOwner {
  int get clientId;

  /// Query bound to [clientId]. It never resolves the active account.
  Future<Map<String, dynamic>> query(Map<String, dynamic> request);

  /// False once the user switched accounts, this slot's client was replaced or
  /// closed, or shutdown started. Anything collected after that point belongs
  /// to an account the sheet no longer represents.
  bool get isCurrent;
}

/// Supplies the owner a notification-exception sheet runs against.
abstract interface class NotificationExceptionAccounts {
  static final NotificationExceptionAccounts defaultAccounts =
      TdNotificationExceptionAccounts();

  /// Null when nothing can be pinned: nothing logged in, shutdown already
  /// running, or a client replaced between the registry reads.
  NotificationExceptionOwner? pinActiveOwner();
}

final class TdNotificationExceptionOwner implements NotificationExceptionOwner {
  TdNotificationExceptionOwner(this._client, this._slot, this.clientId);

  final TdClient _client;
  final int _slot;

  @override
  final int clientId;

  @override
  Future<Map<String, dynamic>> query(Map<String, dynamic> request) =>
      _client.queryTo(request, clientId);

  @override
  bool get isCurrent =>
      // Shutdown refuses queries before the slot and active-client mappings
      // necessarily disappear, so the latch belongs to "still this account".
      !_client.isShuttingDown &&
      _client.clientId(_slot) == clientId &&
      _client.activeClientId == clientId;
}

/// Production pinning against [TdClient.shared], or a test registry when one is
/// supplied.
final class TdNotificationExceptionAccounts
    implements NotificationExceptionAccounts {
  TdNotificationExceptionAccounts({TdClient? client})
    : _client = client ?? TdClient.shared;

  final TdClient _client;

  @override
  NotificationExceptionOwner? pinActiveOwner() {
    if (_client.isShuttingDown) return null;
    final slot = _client.activeSlot;
    final clientId = _client.activeClientId;
    if (clientId == 0) return null;
    // A session swap can replace the slot's client between those two reads;
    // pinning that would query an account the sheet was never opened for.
    if (_client.clientId(slot) != clientId) return null;
    return TdNotificationExceptionOwner(_client, slot, clientId);
  }
}

/// Opens the exception list for [scope] in the app's sheet frame.
///
/// The foreground account is pinned here, before the route is pushed, and every
/// request the sheet makes is bound to that owner.
Future<void> showNotificationExceptionsSheet({
  required BuildContext context,
  required String scope,
  required String title,
  required Map<String, dynamic> scopeSettings,
  Future<void> Function(int chatId, String title)? onOpenChat,
  Future<void> Function()? onExceptionsChanged,
  NotificationExceptionAccounts? accounts,
}) {
  final owner = (accounts ?? NotificationExceptionAccounts.defaultAccounts)
      .pinActiveOwner();
  return showAppModalSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => NotificationExceptionsSheet(
      scope: scope,
      title: title,
      scopeSettings: scopeSettings,
      onOpenChat: onOpenChat,
      onExceptionsChanged: onExceptionsChanged,
      owner: owner,
    ),
  );
}

class NotificationExceptionsSheet extends StatefulWidget {
  const NotificationExceptionsSheet({
    super.key,
    required this.scope,
    required this.title,
    required this.scopeSettings,
    this.onOpenChat,
    this.onExceptionsChanged,
    this.owner,
  });

  /// A `notificationSettingsScope*` value, or [storiesNotificationScope].
  final String scope;

  /// The scope's display name, used as the sheet header.
  final String title;

  /// The scope settings the rows are compared against.
  final Map<String, dynamic> scopeSettings;

  final Future<void> Function(int chatId, String title)? onOpenChat;

  /// Runs after a reset so the page can re-read its scope count.
  final Future<void> Function()? onExceptionsChanged;

  /// Pinned by [showNotificationExceptionsSheet] before the route is pushed.
  /// Null when nothing could be pinned; the sheet then shows its failure state
  /// and never falls through to the foreground client.
  final NotificationExceptionOwner? owner;

  @override
  State<NotificationExceptionsSheet> createState() =>
      _NotificationExceptionsSheetState();
}

class _NotificationExceptionsSheetState
    extends State<NotificationExceptionsSheet> {
  final Set<int> _resetting = {};
  NotificationExceptionOwner? _owner;
  List<_NotificationExceptionEntry> _entries = const [];
  int _loadGeneration = 0;
  bool _loading = true;
  bool _failed = false;
  bool _closedForStaleOwner = false;

  @override
  void initState() {
    super.initState();
    _owner = widget.owner;
    if (_owner == null) {
      // Nothing could be pinned: show the failure state rather than letting a
      // request fall through to the foreground client.
      _loading = false;
      _failed = true;
      return;
    }
    unawaited(_load());
  }

  /// Ends the sheet when the account it was opened for is gone.
  ///
  /// Every await in this state calls this before touching the result: a list,
  /// detail or reset response from an account the user already left must not
  /// populate or mutate the replacement account's UI.
  bool _stopIfOwnerLost() {
    if (!mounted) return true;
    final owner = _owner;
    if (owner != null && owner.isCurrent) return false;
    _closeForStaleOwner();
    return true;
  }

  void _closeForStaleOwner() {
    if (_closedForStaleOwner) return;
    _closedForStaleOwner = true;
    final navigator = Navigator.maybeOf(context);
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    }
  }

  bool _abandonIfStale(int generation) {
    if (!mounted || generation != _loadGeneration) return true;
    return _stopIfOwnerLost();
  }

  void _retry() {
    // Without an owner there is nothing safe to retry: re-pinning here could
    // bind the sheet to an account it was not opened for.
    if (_owner == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final owner = _owner;
    if (owner == null || _stopIfOwnerLost()) return;
    final generation = ++_loadGeneration;
    try {
      final chatIds = await _queryChatIds(owner);
      if (_abandonIfStale(generation)) return;
      final entries = <_NotificationExceptionEntry>[];
      for (final chatId in chatIds) {
        final entry = await _resolve(owner, chatId);
        if (entry == null || !mounted || generation != _loadGeneration) {
          return;
        }
        entries.add(entry);
      }
      if (_abandonIfStale(generation)) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (_abandonIfStale(generation)) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<List<int>> _queryChatIds(NotificationExceptionOwner owner) async {
    if (widget.scope == storiesNotificationScope) {
      final result = await owner.query({
        '@type': 'getStoryNotificationSettingsExceptions',
      });
      return result.int64Array('chat_ids') ?? const [];
    }
    final result = await owner.query({
      '@type': 'getChatNotificationSettingsExceptions',
      'scope': {'@type': widget.scope},
      'compare_sound': true,
    });
    return result.int64Array('chat_ids') ?? const [];
  }

  /// Resolves one row, or null when the pinned owner was lost mid-flight.
  Future<_NotificationExceptionEntry?> _resolve(
    NotificationExceptionOwner owner,
    int chatId,
  ) async {
    String? title;
    TdFileRef? photo;
    Map<String, dynamic>? settings;
    try {
      final chat = await owner.query({'@type': 'getChat', 'chat_id': chatId});
      if (_stopIfOwnerLost()) return null;
      title = chat.str('title');
      photo = TDParse.smallPhoto(chat.obj('photo'));
      settings = chat.obj('notification_settings');
    } catch (_) {
      if (_stopIfOwnerLost()) return null;
      // The chat stays listed so it can still be reset; only its title and
      // deviation fall back.
    }
    final deviations = notificationExceptionDeviations(
      chatSettings: settings,
      scopeSettings: widget.scopeSettings,
      stories: widget.scope == storiesNotificationScope,
    );
    return _NotificationExceptionEntry(
      chatId: chatId,
      title: title != null && title.trim().isNotEmpty
          ? title
          : AppStrings.t(AppStringKeys.notificationExceptionChatValue1, {
              'value1': chatId,
            }),
      photo: photo,
      description: deviations.isEmpty
          ? AppStrings.t(AppStringKeys.notificationExceptionCustom)
          : deviations.take(2).join(' · '),
    );
  }

  void _openChat(_NotificationExceptionEntry entry) {
    if (_stopIfOwnerLost()) return;
    Navigator.of(context).pop();
    final onOpenChat = widget.onOpenChat;
    if (onOpenChat != null) {
      unawaited(onOpenChat(entry.chatId, entry.title));
    }
  }

  Future<void> _reset(_NotificationExceptionEntry entry) async {
    if (_resetting.contains(entry.chatId)) return;
    final owner = _owner;
    if (owner == null || _stopIfOwnerLost()) return;
    setState(() => _resetting.add(entry.chatId));
    try {
      await owner.query({
        '@type': 'setChatNotificationSettings',
        'chat_id': entry.chatId,
        'notification_settings': resetChatNotificationSettingsPayload(),
      });
    } catch (_) {
      if (!mounted || _stopIfOwnerLost()) return;
      setState(() => _resetting.remove(entry.chatId));
      showToast(
        context,
        AppStringKeys.notificationExceptionResetFailed.l10n(context),
      );
      return;
    }
    if (_stopIfOwnerLost()) return;
    setState(() {
      _resetting.remove(entry.chatId);
      _entries = _entries
          .where((existing) => existing.chatId != entry.chatId)
          .toList(growable: false);
    });
    final onExceptionsChanged = widget.onExceptionsChanged;
    if (onExceptionsChanged != null && !_stopIfOwnerLost()) {
      await onExceptionsChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final header = widget.title;
    return SafeArea(
      top: false,
      child: SettingsPanel(
        key: const ValueKey('notification-exceptions-sheet'),
        margin: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xxl,
                  AppSpacing.lg,
                  AppSpacing.xxl,
                  AppSpacing.md,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      header,
                      style: AppTextStyle.title(
                        c.textPrimary,
                        weight: AppTextWeight.semibold,
                      ),
                    ),
                    if (!_loading && !_failed && _entries.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        notificationExceptionCountLabel(_entries.length),
                        style: AppTextStyle.footnote(c.textTertiary),
                      ),
                    ],
                  ],
                ),
              ),
              const SettingsDivider(),
              Flexible(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        key: ValueKey('notification-exceptions-loading'),
        padding: EdgeInsets.all(AppSpacing.xxl),
        child: Center(child: AppActivityIndicator(size: 24)),
      );
    }
    if (_failed) return _Failure(onRetry: _owner == null ? null : _retry);
    if (_entries.isEmpty) {
      return Padding(
        key: const ValueKey('notification-exceptions-empty'),
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Text(
          AppStringKeys.notificationExceptionEmpty.l10n(context),
          textAlign: TextAlign.center,
          style: AppTextStyle.footnote(context.colors.textTertiary),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: _entries.length,
      itemBuilder: (context, index) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (index > 0) const SettingsDivider(),
          _ExceptionRow(
            entry: _entries[index],
            resetting: _resetting.contains(_entries[index].chatId),
            onTap: () => _openChat(_entries[index]),
            onReset: () => unawaited(_reset(_entries[index])),
          ),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({this.onRetry});

  /// Null when nothing could be pinned, so there is no safe retry.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('notification-exceptions-error'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xxl,
            AppSpacing.xl,
            AppSpacing.xxl,
            AppSpacing.sm,
          ),
          child: Text(
            AppStringKeys.notificationExceptionLoadFailed.l10n(context),
            textAlign: TextAlign.center,
            style: AppTextStyle.footnote(context.colors.textTertiary),
          ),
        ),
        if (onRetry != null)
          SettingsRow(
            key: const ValueKey('notification-exceptions-retry'),
            title: AppStringKeys.notificationExceptionRetry.l10n(context),
            leading: const SettingsLeadingIcon(icon: HeroAppIcons.rotateLeft),
            showChevron: false,
            onTap: onRetry,
          ),
      ],
    );
  }
}

class _ExceptionRow extends StatelessWidget {
  const _ExceptionRow({
    required this.entry,
    required this.resetting,
    required this.onTap,
    required this.onReset,
  });

  final _NotificationExceptionEntry entry;
  final bool resetting;
  final VoidCallback onTap;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Expanded(
          child: AppInteractiveSurface(
            key: ValueKey('notification-exception-${entry.chatId}'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              child: Row(
                children: [
                  PhotoAvatar(
                    title: entry.title,
                    photo: entry.photo,
                    size: 40,
                    allowAnimation: false,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.body(c.textPrimary),
                        ),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          entry.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.footnote(c.textTertiary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
          child: resetting
              ? const Padding(
                  padding: EdgeInsets.all(AppSpacing.sm),
                  child: AppActivityIndicator(size: 18),
                )
              : AppInteractiveSurface(
                  key: ValueKey('notification-exception-reset-${entry.chatId}'),
                  onTap: onReset,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  semanticLabel: AppStringKeys.notificationExceptionReset.l10n(
                    context,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    child: Text(
                      AppStringKeys.notificationExceptionReset.l10n(context),
                      style: AppTextStyle.callout(AppTheme.brand),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _NotificationExceptionEntry {
  const _NotificationExceptionEntry({
    required this.chatId,
    required this.title,
    required this.description,
    this.photo,
  });

  final int chatId;
  final String title;
  final String description;
  final TdFileRef? photo;
}
