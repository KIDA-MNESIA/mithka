import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/config/build_flags.dart';
import 'package:mithka/history/message_history_store.dart';
import 'package:mithka/history/message_history_view.dart';
import 'package:mithka/settings/ghost_mode_controller.dart';
import 'package:mithka/settings/ghost_mode_settings_view.dart';
import 'package:mithka/tdlib/td_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (allowTelegramTosViolations) {
    test('entry points are explicitly enabled in this variant', () {
      expect(allowTelegramTosViolations, isTrue);
    });
    return;
  }

  test('the direct presence action remains inert without the opt-in', () async {
    final sent = <Map<String, dynamic>>[];
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (_) async => {'@type': 'ok'},
        send: (request) async => sent.add(request),
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
    addTearDown(TdClient.shared.closeProxy);
    GhostModeController.shared.applyOnlineStatusToClient(
      false,
      TdClient.shared.activeClientId,
      TdClient.shared,
    );
    await Future<void>.delayed(Duration.zero);
    expect(sent, isEmpty);
  });

  testWidgets('direct feature pages are absent without the opt-in', (
    tester,
  ) async {
    final store = MessageHistoryStore.forTesting();
    addTearDown(store.dispose);
    var subscriptions = 0;
    store.updateSource = (_) {
      subscriptions++;
      return const Stream<Map<String, dynamic>>.empty();
    };
    for (final page in [
      const GhostModeSettingsView(),
      MessageHistoryView(store: store),
      MessageHistoryExcludedChatsView(store: store, chatLabel: (_) => 'chat'),
    ]) {
      await tester.pumpWidget(
        Directionality(textDirection: TextDirection.ltr, child: page),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Text), findsNothing);
    }
    expect(subscriptions, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
