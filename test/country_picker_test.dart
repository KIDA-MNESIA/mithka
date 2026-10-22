import 'package:dlibphonenumber/dlibphonenumber.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/country_picker.dart';
import 'package:mithka/theme/app_theme.dart';

void main() {
  testWidgets(
    'missing countries can be searched and selected on a narrow phone',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      Country? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [AppColors.light]),
          home: CountryPickerView(onSelect: (country) => selected = country),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), '+350');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InkWell, '+350'), findsOneWidget);
      await tester.tap(find.widgetWithText(InkWell, '+350'));
      expect(selected?.iso, 'GI');
      expect(selected?.dial, '350');
    },
  );

  test(
    'offline picker contains every supported geographical calling region',
    () {
      final phone = PhoneNumberUtil.instance;
      expect(
        Country.all.map((c) => c.iso).toSet(),
        phone.supportedRegions.toSet(),
      );
      expect(Country.all.map((c) => c.iso).toSet().length, Country.all.length);
      for (final country in Country.all) {
        expect(
          country.dial,
          '${phone.getCountryCodeForRegion(country.iso)}',
          reason: country.iso,
        );
      }
    },
  );

  test(
    'reported missing calling codes resolve without dropping their last digit',
    () {
      const codes = {
        '220': 'GM',
        '240': 'GQ',
        '290': 'SH',
        '350': 'GI',
        '370': 'LT',
        '380': 'UA',
        '500': 'FK',
        '590': 'GP',
        '680': 'PW',
        '674': 'NR',
        '681': 'WF',
        '682': 'CK',
        '683': 'NU',
        '686': 'KI',
        '687': 'NC',
        '688': 'TV',
        '689': 'PF',
        '690': 'TK',
        '691': 'FM',
        '692': 'MH',
        '992': 'TJ',
      };
      for (final entry in codes.entries) {
        expect(
          Country.match(entry.key)?.iso,
          entry.value,
          reason: '+${entry.key}',
        );
      }
    },
  );

  test('shared calling codes retain their primary region while typing', () {
    for (final entry in {
      '1': 'US',
      '7': 'RU',
      '44': 'GB',
      '39': 'IT',
      '47': 'NO',
      '61': 'AU',
      '212': 'MA',
      '262': 'RE',
      '358': 'FI',
      '590': 'GP',
      '599': 'CW',
    }.entries) {
      expect(Country.match(entry.key)?.iso, entry.value);
    }
  });
  test('shared +7 Kazakhstan prefixes resolve to Kazakhstan while typing', () {
    expect(Country.match('77')?.iso, 'KZ');
    expect(Country.match('7701')?.iso, 'KZ');
    expect(Country.match('76')?.iso, 'KZ');
  });

  test('shared +7 Russian prefixes remain Russia', () {
    expect(Country.match('7912')?.iso, 'RU');
    expect(Country.match('7495')?.iso, 'RU');
  });
}
