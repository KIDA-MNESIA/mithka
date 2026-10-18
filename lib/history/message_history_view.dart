//
//  message_history_view.dart
//
//  The local message-history viewer: every mirrored copy of what this
//  account received, including messages the counterpart deleted or edited
//  afterwards. Filter by one chat, clear a single chat or everything, and
//  exclude chats from recording. Opened from Advanced settings behind the
//  compile-time [allowTelegramTosViolations] gate.
//

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../components/app_confirm_dialog.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/toast.dart';
import '../components/ui_components.dart';
import '../config/build_flags.dart';
import '../l10n/app_localizations.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'message_history_store.dart';

/// The mirror marks a message deleted the moment the update arrives, so
/// freshly deleted rows would otherwise flicker while TDLib confirms the
/// removal. This keeps the 'Deleted' label off rows younger than this.
const _deletedGrace = Duration(seconds: 5);

class MessageHistoryView extends StatefulWidget {
  const MessageHistoryView({super.key, this.chatId, this.store});

  /// Pre-filters the list to this chat; the viewer can still switch.
  final int? chatId;

  /// Injectable for tests; defaults to the shared store.
  final MessageHistoryStore? store;

  @override
  State<MessageHistoryView> createState() => _MessageHistoryViewState();
}

class _MessageHistoryViewState extends State<MessageHistoryView> {
  late MessageHistoryStore _store;
  late int? _chatId;
  Map<int, String> _chatTitles = const {};
  bool _resolvingTitles = false;
  int? _titleAccountUserId;
  int _titleResolutionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? MessageHistoryStore.shared;
    _chatId = widget.chatId;
    if (!allowTelegramTosViolations) return;
    _titleAccountUserId = _store.activeAccountUserId;
    _store.addListener(_onStore);
    unawaited(_store.ensureLoaded());
    _maybeResolveChatTitles();
  }

  @override
  void dispose() {
    _store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (_titleAccountUserId != _store.activeAccountUserId) {
      _titleAccountUserId = _store.activeAccountUserId;
      _titleResolutionGeneration++;
      _resolvingTitles = false;
      _chatTitles = const {};
      _chatId = null;
    }
    if (mounted) setState(() {});
    _maybeResolveChatTitles();
  }

  /// Resolves display titles for every chat that has kept copies, once the
  /// set of chats is not fully covered yet. Failures keep the localized
  /// "Chat {id}" fallback.
  void _maybeResolveChatTitles() {
    if (_resolvingTitles) return;
    final wanted = {for (final entry in _store.entries) entry.chatId};
    if (_chatTitles.keys.toSet().containsAll(wanted)) return;
    _resolvingTitles = true;
    unawaited(_resolveChatTitles(wanted, ++_titleResolutionGeneration));
  }

  Future<void> _resolveChatTitles(Set<int> chatIds, int generation) async {
    final clientId = TdClient.shared.activeClientId;
    final resolved = <int, String>{};
    for (final chatId in chatIds) {
      if (!mounted || generation != _titleResolutionGeneration) return;
      try {
        final chat = await TdClient.shared.queryTo({
          '@type': 'getChat',
          'chat_id': chatId,
        }, clientId);
        final title = chat.str('title');
        if (title != null && title.isNotEmpty) resolved[chatId] = title;
      } catch (_) {
        // Fall through to the localized "Chat {id}" label.
      }
    }
    if (!mounted || generation != _titleResolutionGeneration) return;
    if (resolved.isNotEmpty) {
      setState(() => _chatTitles = {..._chatTitles, ...resolved});
    }
    _resolvingTitles = false;
  }

  String _chatLabel(int chatId) =>
      _chatTitles[chatId] ??
      AppStrings.t(AppStringKeys.historyChatLabel, {'value1': '$chatId'});

  Future<void> _confirmClearAll() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: AppStringKeys.historyClearAllConfirmTitle.l10n(context),
      confirmText: AppStringKeys.historyClearAction.l10n(context),
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    _store.clearAll();
    if (!mounted) return;
    setState(() => _chatId = null);
    showToast(context, AppStringKeys.historyClearedToast.l10n(context));
  }

  Future<void> _confirmClearChat(int chatId) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: AppStrings.t(AppStringKeys.historyClearChatConfirmTitle, {
        'value1': _chatLabel(chatId),
      }),
      confirmText: AppStringKeys.historyClearAction.l10n(context),
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    _store.clearChat(chatId);
    if (!mounted) return;
    if (_chatId == chatId) {
      setState(() => _chatId = null);
    } else {
      setState(() {});
    }
    showToast(context, AppStringKeys.historyClearedToast.l10n(context));
  }

  @override
  Widget build(BuildContext context) {
    if (!allowTelegramTosViolations) return const SizedBox.shrink();
    final all = _store.entries;
    final visible = _chatId == null
        ? all.reversed.toList()
        : all.reversed.where((entry) => entry.chatId == _chatId).toList();
    final chatId = _chatId;

    return SettingsPageScaffold(
      title: AppStringKeys.historyTitle.l10n(context),
      onBack: () => Navigator.of(context).pop(),
      trailingIcon: HeroAppIcons.trash,
      // Unfiltered: the header clears everything. Filtered: it clears the
      // chat in view, which is the narrower clear the user is looking at.
      onTrailing: visible.isEmpty
          ? null
          : chatId == null
          ? _confirmClearAll
          : () => unawaited(_confirmClearChat(chatId)),
      child: SettingsListView(
        children: [
          SettingsCard.rows(
            rows: [
              // Excluded chats stay recorded nowhere, so the filter needs a
              // manual re-entry point for them.
              SettingsRow(
                title: AppStringKeys.historyExcludedTitle.l10n(context),
                value: '${_store.excludedChats.length}',
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.eyeSlash),
                onTap: _openExcludedChats,
              ),
            ],
          ),
          if (visible.isEmpty)
            const SettingsNote(
              key: ValueKey('history-view-empty'),
              text: AppStringKeys.historyEmpty,
            )
          else ...[
            SettingsCard.rows(
              rows: [
                for (final entry in visible)
                  _HistoryEntryRow(
                    key: ValueKey('history-${entry.key}'),
                    entry: entry,
                    chatLabel: _chatLabel(entry.chatId),
                    onOpenChat: () => setState(() => _chatId = entry.chatId),
                  ),
              ],
            ),
            if (chatId != null)
              const SettingsNote(text: AppStringKeys.historyFilteredNote),
          ],
        ],
      ),
    );
  }

  void _openExcludedChats() {
    Navigator.of(context).push(
      AppPageRoute<void>(
        pageBuilder: (_, _, _) => MessageHistoryExcludedChatsView(
          store: _store,
          chatLabel: _chatLabel,
        ),
      ),
    );
  }
}

class _HistoryEntryRow extends StatelessWidget {
  const _HistoryEntryRow({
    super.key,
    required this.entry,
    required this.chatLabel,
    required this.onOpenChat,
  });

  final MessageHistoryEntry entry;
  final String chatLabel;
  final VoidCallback onOpenChat;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final deleted = entry.state == MessageHistoryState.deleted;
    // Keep the Deleted label off rows whose updateDeleteMessages only just
    // landed; the chat transcript usually catches up within a moment.
    // deletedAt 0 means the deletion was observed this very second.
    final deletedAgeSeconds = entry.deletedAt <= 0
        ? 0
        : DateTime.now().millisecondsSinceEpoch ~/ 1000 - entry.deletedAt;
    final freshlyDeleted =
        deleted && deletedAgeSeconds < _deletedGrace.inSeconds;
    final kindSuffix = entry.kindKey;
    final kindText = kindSuffix.isEmpty
        ? ''
        : AppStrings.t(_kindKey(suffix: kindSuffix));
    final statusParts = <String>[
      if (deleted && !freshlyDeleted)
        AppStringKeys.historyDeletedLabel.l10n(context),
      if (entry.isEdited) AppStringKeys.historyEditedLabel.l10n(context),
      if (kindText.isNotEmpty) kindText,
    ];

    return AppInteractiveSurface(
      onTap: onOpenChat,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (deleted && !freshlyDeleted) ...[
                  AppIcon(
                    HeroAppIcons.trash,
                    size: AppIconSize.sm,
                    color: c.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(
                  child: Text(
                    chatLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.footnote(c.textSecondary),
                  ),
                ),
                Text(
                  _formatTime(entry.date),
                  style: AppTextStyle.footnote(c.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              entry.text.isEmpty
                  ? _emptyTextFallback(kindSuffix, context)
                  : entry.text,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style:
                  AppTextStyle.body(
                    deleted && !freshlyDeleted
                        ? c.textSecondary
                        : c.textPrimary,
                  ).copyWith(
                    fontStyle: deleted && !freshlyDeleted
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
            ),
            if (statusParts.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                statusParts.join(' · '),
                style: AppTextStyle.footnote(c.textTertiary),
              ),
            ],
            for (final event in entry.events) ...[
              const SizedBox(height: 2),
              Text(
                AppStrings.t(AppStringKeys.historyEditEvent, {
                  'value1': _formatTime(event.at),
                  'value2': event.newText.isEmpty
                      ? _emptyTextFallback(kindSuffix, context)
                      : event.newText,
                }),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.footnote(c.textTertiary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _emptyTextFallback(String kindSuffix, BuildContext context) =>
      kindSuffix.isEmpty
      ? AppStringKeys.historyKindUnknown.l10n(context)
      : AppStrings.t(_kindKey(suffix: kindSuffix));

  String _kindKey({required String suffix}) => switch (suffix) {
    'historyKindPhoto' => AppStringKeys.historyKindPhoto,
    'historyKindVideo' => AppStringKeys.historyKindVideo,
    'historyKindVideoNote' => AppStringKeys.historyKindVideoNote,
    'historyKindVoice' => AppStringKeys.historyKindVoice,
    'historyKindAnimation' => AppStringKeys.historyKindAnimation,
    'historyKindSticker' => AppStringKeys.historyKindSticker,
    'historyKindDocument' => AppStringKeys.historyKindDocument,
    'historyKindAudio' => AppStringKeys.historyKindAudio,
    'historyKindPoll' => AppStringKeys.historyKindPoll,
    'historyKindLocation' => AppStringKeys.historyKindLocation,
    'historyKindContact' => AppStringKeys.historyKindContact,
    'historyKindDice' => AppStringKeys.historyKindDice,
    _ => AppStringKeys.historyKindUnknown,
  };

  String _formatTime(int unixSeconds) {
    final t = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// Chats the mirror must not record, with re-include actions.
class MessageHistoryExcludedChatsView extends StatelessWidget {
  const MessageHistoryExcludedChatsView({
    super.key,
    required this.store,
    required this.chatLabel,
  });

  final MessageHistoryStore store;
  final String Function(int chatId) chatLabel;

  @override
  Widget build(BuildContext context) {
    if (!allowTelegramTosViolations) return const SizedBox.shrink();
    return SettingsPageScaffold(
      title: AppStringKeys.historyExcludedTitle.l10n(context),
      onBack: () => Navigator.of(context).pop(),
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final chats = store.excludedChats.toList()..sort();
          return SettingsListView(
            children: [
              if (chats.isEmpty)
                const SettingsNote(text: AppStringKeys.historyNoExcludedChats)
              else
                SettingsCard.rows(
                  rows: [
                    for (final chatId in chats)
                      SettingsRow(
                        key: ValueKey('history-excluded-$chatId'),
                        title: chatLabel(chatId),
                        value: AppStringKeys.historyReincludeAction.l10n(
                          context,
                        ),
                        onTap: () => store.includeChat(chatId),
                      ),
                  ],
                ),
              const SettingsNote(text: AppStringKeys.historyExcludedNote),
            ],
          );
        },
      ),
    );
  }
}
