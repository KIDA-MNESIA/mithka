import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/profile/profile_detail_view.dart';
import 'package:mithka/settings/edit_profile_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A profile shows its bio once, in the header and in full, and offers the
/// edit pen only when the profile belongs to the signed-in account.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const meId = 777;
  const otherId = 888;
  const longBio =
      'Cat person. Collector of tea tins, slow mornings and long train '
      'journeys across the mountains. Ask me about the 2019 hike — the '
      'answer takes a while, which is exactly the point of asking.';

  late Future<Map<String, dynamic>> Function(Map<String, dynamic>) handler;

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) => handler(request),
        send: (_) async {},
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
  });

  tearDownAll(TdClient.shared.closeProxy);

  void serveProfile({String bio = longBio}) {
    handler = (request) async {
      switch (request['@type']) {
        case 'getMe':
          return {'@type': 'user', 'id': meId, 'first_name': 'Me'};
        case 'getUser':
          return {
            '@type': 'user',
            'id': request['user_id'],
            'first_name': 'ieb',
            'last_name': '',
            'phone_number': '37281981998',
            'usernames': {
              '@type': 'usernames',
              'active_usernames': ['nekoko14'],
              'editable_username': 'nekoko14',
            },
            'type': {'@type': 'userTypeRegular'},
            'status': {'@type': 'userStatusOffline', 'was_online': 0},
          };
        case 'getUserFullInfo':
          return {
            '@type': 'userFullInfo',
            if (bio.isNotEmpty) 'bio': {'@type': 'formattedText', 'text': bio},
          };
        case 'getUserProfilePhotos':
          return {'@type': 'photos', 'total_count': 0, 'photos': <dynamic>[]};
        case 'createPrivateChat':
          return {
            '@type': 'chat',
            'id': 42,
            'action_bar': {'@type': 'chatActionBarNone'},
          };
        default:
          return {'@type': 'ok'};
      }
    };
  }

  Future<void> pumpProfile(WidgetTester tester, {required int id}) async {
    // The test font draws every glyph at full width; a wider surface keeps the
    // fixed bottom bar laid out. Nothing here asserts on layout.
    tester.view.physicalSize = const Size(560, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final theme = ThemeController(preferences);
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          theme: ThemeData(extensions: [AppColors.light]),
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProfileDetailView(userId: id, name: 'ieb'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder bioText() => find.text(longBio, findRichText: true);

  testWidgets('an other user bio renders in full and offers no edit pen', (
    tester,
  ) async {
    serveProfile();
    await pumpProfile(tester, id: otherId);

    expect(bioText(), findsOneWidget);

    // No maxLines: the whole bio is laid out, so the last sentence exists.
    expect(
      find.textContaining('exactly the point of asking', findRichText: true),
      findsOneWidget,
    );

    // Someone else's bio is not yours to edit — no pen beside it.
    expect(find.byKey(const ValueKey('profileBioEditIcon')), findsNothing);
    // Neither is anything else pen-shaped: the top-right edit button is also
    // own-profile only, so a stranger's page offers no pen at all.
    expect(find.byIcon(HeroAppIcons.pen.data), findsNothing);
  });

  testWidgets('the own profile bio renders in full with the edit pen', (
    tester,
  ) async {
    serveProfile();
    await pumpProfile(tester, id: meId);

    expect(bioText(), findsOneWidget);
    expect(find.byKey(const ValueKey('profileBioEditIcon')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profileBioEditIcon')));
    await tester.pumpAndSettle();
    expect(find.byType(EditProfileView), findsOneWidget);
  });

  testWidgets('the bio is not repeated among the detail rows', (tester) async {
    serveProfile();
    await pumpProfile(tester, id: otherId);

    // Exactly one Bio: the header copy. The old info-card row is gone, so the
    // label the row carried is gone with it.
    expect(bioText(), findsOneWidget);
    expect(
      find.text(AppStrings.t(AppStringKeys.profileDetailBio)),
      findsNothing,
    );
  });
}
