import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_input_bar.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/chat/rich_text_composer_view.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingChatViewModel extends ChatViewModel {
  _RecordingChatViewModel()
    : super(chatId: 1, title: 'Test chat', markReadOnOpen: false);

  final sent = <(String, List<Map<String, dynamic>>)>[];
  var sendAttempts = 0;

  @override
  Future<bool> prepareMessageSend() async => true;

  @override
  Future<bool> currentUserIsPremium() async => false;

  @override
  Future<bool> sendFormatted(
    String text,
    List<Map<String, dynamic>> entities,
  ) async {
    sendAttempts++;
    sent.add((text, entities));
    return true;
  }
}

const _formattedOnlyToast =
    'Sent as a formatted message. Rich blocks were dropped.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  late List<Map<String, dynamic>> requests;

  setUpAll(() {
    requests = <Map<String, dynamic>>[];
    // In-memory transport only: these tests never access a Telegram account.
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(request);
          if (request['@type'] == 'sendMessage') {
            return {'@type': 'message', 'id': 99};
          }
          return {'@type': 'ok'};
        },
        send: (_) async {},
        updates: const Stream.empty(),
      ),
    );
  });
  tearDownAll(TdClient.shared.closeProxy);

  setUp(() {
    requests = [];
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
          if (call.method == 'containsKey') return false;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  testWidgets('the editor opens for a non-Premium account without a relay', (
    tester,
  ) async {
    final vm = _RecordingChatViewModel();
    addTearDown(vm.dispose);
    await _pumpComposer(tester, vm);
    await _openRichTextEditor(tester);

    expect(find.byType(RichTextComposerView), findsOneWidget);
    expect(find.text('Configure a relay bot?'), findsNothing);
  });

  testWidgets('an inline-only document sends as a formatted message', (
    tester,
  ) async {
    final vm = _RecordingChatViewModel();
    addTearDown(vm.dispose);
    await _pumpComposer(tester, vm);
    await _openRichTextEditor(tester);

    await tester.enterText(_composerField(tester).first, 'inline draft');
    await _sendComposer(tester);

    expect(vm.sent, hasLength(1));
    expect(vm.sent.single.$1, 'inline draft');
    expect(find.text('Configure a relay bot?'), findsNothing);
    expect(find.text(_formattedOnlyToast), findsNothing);
    expect(find.byType(RichTextComposerView), findsNothing);
    await _drainToast(tester);
  });

  testWidgets('declining the relay sends the text and reports dropped blocks', (
    tester,
  ) async {
    final vm = _RecordingChatViewModel();
    addTearDown(vm.dispose);
    await _pumpComposer(tester, vm);
    await _openRichTextEditor(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(RichTextComposerView),
        matching: find.text('•'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(_composerField(tester).first, 'milk\nbread');
    await _sendComposer(tester);

    expect(find.text('Configure a relay bot?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(vm.sent, hasLength(1));
    expect(vm.sent.single.$1, 'milk\nbread');
    expect(find.text(_formattedOnlyToast), findsOneWidget);
    expect(find.byType(RichTextComposerView), findsNothing);
    final input = tester.widget<TextField>(_barField(tester).first);
    expect(input.controller?.text, isEmpty);
    await _drainToast(tester);
  });

  testWidgets('bold from the toolbar reaches the sent entities', (
    tester,
  ) async {
    // A plain view model so the send goes through the real request builder and
    // the assertion reads the TDLib request instead of a recording override.
    final vm = ChatViewModel(chatId: 42, title: 'Rich', markReadOnOpen: false);
    addTearDown(vm.dispose);
    await _pumpComposer(tester, vm);
    await _openRichTextEditor(tester);

    final field = _composerField(tester).first;
    await tester.enterText(field, 'hello world');
    final controller = tester.widget<TextField>(field).controller!;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('rich-inline-bold')));
    await tester.pump();

    await _sendComposer(tester);

    final send = requests.firstWhere(
      (request) => request['@type'] == 'sendMessage',
    );
    final content = send['input_message_content'] as Map<String, dynamic>;
    final formatted = content['text'] as Map<String, dynamic>;
    final entities = (formatted['entities'] as List)
        .cast<Map<String, dynamic>>();
    expect(formatted['text'], 'hello world');
    expect(
      entities.any((entity) {
        final type = entity['type'] as Map<String, dynamic>;
        return type['@type'] == 'textEntityTypeBold' &&
            entity['offset'] == 0 &&
            entity['length'] == 5;
      }),
      isTrue,
      reason: 'bold entity missing from $entities',
    );
  });

  testWidgets('inline buttons stay disabled while the selection is collapsed', (
    tester,
  ) async {
    final vm = _RecordingChatViewModel();
    addTearDown(vm.dispose);
    await _pumpComposer(tester, vm);
    await _openRichTextEditor(tester);

    final field = _composerField(tester).first;
    await tester.enterText(field, 'hello world');
    await tester.pump();

    GestureDetector bold() => tester.widget<GestureDetector>(
      find.byKey(const ValueKey('rich-inline-bold')),
    );
    expect(bold().onTap, isNull);

    final controller = tester.widget<TextField>(field).controller!;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();
    expect(bold().onTap, isNotNull);
  });
}

Future<void> _pumpComposer(WidgetTester tester, ChatViewModel viewModel) async {
  final theme = ThemeController(await SharedPreferences.getInstance());
  addTearDown(theme.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatInputBar(
              vm: viewModel,
              onStartCall: (_) {},
              onMessageSent: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openRichTextEditor(WidgetTester tester) async {
  await tester.tap(find.byIcon(HeroAppIcons.circlePlus.data));
  await tester.pump();
  await tester.tap(find.text('Rich text'));
  await tester.pumpAndSettle();
}

Finder _composerField(WidgetTester tester) {
  return find.descendant(
    of: find.byType(RichTextComposerView),
    matching: find.byType(TextField),
  );
}

Finder _barField(WidgetTester tester) {
  return find.descendant(
    of: find.byType(ChatInputBar),
    matching: find.byType(TextField),
  );
}

Future<void> _sendComposer(WidgetTester tester) async {
  await tester.tap(find.text('Send'));
  await tester.pumpAndSettle();
}

/// Lets the transient toast finish its fade-in and hold so the next test does
/// not inherit an overlay entry.
Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}
