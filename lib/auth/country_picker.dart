//
//  country_picker.dart
//
//  Country/region model + picker sheet for the Telegram-style phone login.
//  Dial-code matching uses a bundled offline table. Display names are replaced
//  at runtime by Telegram's localized `getCountries` response, matching the
//  official clients while keeping phone login available offline.
//

import 'dart:async';

import 'package:dlibphonenumber/dlibphonenumber.dart';
import 'package:flutter/material.dart';
import 'package:mithka/l10n/app_localizations.dart';

import '../components/app_icons.dart';
import '../components/country_flag.dart';
import '../theme/app_theme.dart';
import 'telegram_country_names.dart';

class Country {
  const Country(this.name, this.iso, this.dial);
  final String name; // Offline localized display-name key
  final String iso; // ISO 3166-1 alpha-2
  final String dial; // dial code, digits only

  String displayName(Map<String, String> telegramNames) =>
      telegramNames[iso] ?? AppStrings.t(name);

  /// Flag emoji derived from the ISO code (regional-indicator scalars).
  String get flag {
    const base = 0x1F1E6;
    final buf = StringBuffer();
    for (final c in iso.toUpperCase().codeUnits) {
      if (c >= 65 && c <= 90) buf.writeCharCode(base + (c - 65));
    }
    return buf.toString();
  }

  static const Country china = Country(AppStringKeys.countryCN, 'CN', '86');

  /// Every geographical region in the bundled libphonenumber metadata.
  /// Shared calling codes use libphonenumber leading-digit metadata before
  /// falling back to a canonical display country.
  static const List<Country> all = [
    // East Asia
    Country(AppStringKeys.countryCN, 'CN', '86'),
    Country(AppStringKeys.countryHK, 'HK', '852'),
    Country(AppStringKeys.countryMO, 'MO', '853'),
    Country(AppStringKeys.countryTW, 'TW', '886'),
    Country(AppStringKeys.countryJP, 'JP', '81'),
    Country(AppStringKeys.countryKR, 'KR', '82'),
    Country(AppStringKeys.countryKP, 'KP', '850'),
    Country(AppStringKeys.countryMN, 'MN', '976'),
    // Southeast Asia
    Country(AppStringKeys.countrySG, 'SG', '65'),
    Country(AppStringKeys.countryMY, 'MY', '60'),
    Country(AppStringKeys.countryTH, 'TH', '66'),
    Country(AppStringKeys.countryVN, 'VN', '84'),
    Country(AppStringKeys.countryID, 'ID', '62'),
    Country(AppStringKeys.countryPH, 'PH', '63'),
    Country(AppStringKeys.countryKH, 'KH', '855'),
    Country(AppStringKeys.countryMM, 'MM', '95'),
    Country(AppStringKeys.countryLA, 'LA', '856'),
    Country(AppStringKeys.countryBN, 'BN', '673'),
    Country(AppStringKeys.countryTL, 'TL', '670'),
    // South Asia
    Country(AppStringKeys.countryIN, 'IN', '91'),
    Country(AppStringKeys.countryPK, 'PK', '92'),
    Country(AppStringKeys.countryBD, 'BD', '880'),
    Country(AppStringKeys.countryLK, 'LK', '94'),
    Country(AppStringKeys.countryNP, 'NP', '977'),
    Country(AppStringKeys.countryBT, 'BT', '975'),
    Country(AppStringKeys.countryMV, 'MV', '960'),
    Country(AppStringKeys.countryAF, 'AF', '93'),
    // Central Asia
    Country(AppStringKeys.countryKZ, 'KZ', '7'),
    Country(AppStringKeys.countryUZ, 'UZ', '998'),
    Country(AppStringKeys.countryTM, 'TM', '993'),
    Country(AppStringKeys.countryTJ, 'TJ', '992'),
    Country(AppStringKeys.countryKG, 'KG', '996'),
    // Middle East
    Country(AppStringKeys.countryAE, 'AE', '971'),
    Country(AppStringKeys.countrySA, 'SA', '966'),
    Country(AppStringKeys.countryIL, 'IL', '972'),
    Country(AppStringKeys.countryPS, 'PS', '970'),
    Country(AppStringKeys.countryQA, 'QA', '974'),
    Country(AppStringKeys.countryKW, 'KW', '965'),
    Country(AppStringKeys.countryBH, 'BH', '973'),
    Country(AppStringKeys.countryOM, 'OM', '968'),
    Country(AppStringKeys.countryJO, 'JO', '962'),
    Country(AppStringKeys.countryLB, 'LB', '961'),
    Country(AppStringKeys.countryIQ, 'IQ', '964'),
    Country(AppStringKeys.countryIR, 'IR', '98'),
    Country(AppStringKeys.countrySY, 'SY', '963'),
    Country(AppStringKeys.countryYE, 'YE', '967'),
    Country(AppStringKeys.countryTR, 'TR', '90'),
    Country(AppStringKeys.countryGE, 'GE', '995'),
    Country(AppStringKeys.countryAM, 'AM', '374'),
    Country(AppStringKeys.countryAZ, 'AZ', '994'),
    // Europe
    Country(AppStringKeys.countryGB, 'GB', '44'),
    Country(AppStringKeys.countryIE, 'IE', '353'),
    Country(AppStringKeys.countryFR, 'FR', '33'),
    Country(AppStringKeys.countryDE, 'DE', '49'),
    Country(AppStringKeys.countryIT, 'IT', '39'),
    Country(AppStringKeys.countryES, 'ES', '34'),
    Country(AppStringKeys.countryPT, 'PT', '351'),
    Country(AppStringKeys.countryNL, 'NL', '31'),
    Country(AppStringKeys.countryBE, 'BE', '32'),
    Country(AppStringKeys.countryLU, 'LU', '352'),
    Country(AppStringKeys.countryCH, 'CH', '41'),
    Country(AppStringKeys.countryAT, 'AT', '43'),
    Country(AppStringKeys.countrySE, 'SE', '46'),
    Country(AppStringKeys.countryNO, 'NO', '47'),
    Country(AppStringKeys.countryDK, 'DK', '45'),
    Country(AppStringKeys.countryFI, 'FI', '358'),
    Country(AppStringKeys.countryIS, 'IS', '354'),
    Country(AppStringKeys.countryPL, 'PL', '48'),
    Country(AppStringKeys.countryCZ, 'CZ', '420'),
    Country(AppStringKeys.countrySK, 'SK', '421'),
    Country(AppStringKeys.countryHU, 'HU', '36'),
    Country(AppStringKeys.countryRO, 'RO', '40'),
    Country(AppStringKeys.countryBG, 'BG', '359'),
    Country(AppStringKeys.countryGR, 'GR', '30'),
    Country(AppStringKeys.countryRU, 'RU', '7'),
    Country(AppStringKeys.countryUA, 'UA', '380'),
    Country(AppStringKeys.countryBY, 'BY', '375'),
    Country(AppStringKeys.countryMD, 'MD', '373'),
    Country(AppStringKeys.countryLT, 'LT', '370'),
    Country(AppStringKeys.countryLV, 'LV', '371'),
    Country(AppStringKeys.countryEE, 'EE', '372'),
    Country(AppStringKeys.countryRS, 'RS', '381'),
    Country(AppStringKeys.countryHR, 'HR', '385'),
    Country(AppStringKeys.countrySI, 'SI', '386'),
    Country(AppStringKeys.countryBA, 'BA', '387'),
    Country(AppStringKeys.countryMK, 'MK', '389'),
    Country(AppStringKeys.countryAL, 'AL', '355'),
    Country(AppStringKeys.countryME, 'ME', '382'),
    Country(AppStringKeys.countryXK, 'XK', '383'),
    Country(AppStringKeys.countryMT, 'MT', '356'),
    Country(AppStringKeys.countryCY, 'CY', '357'),
    Country(AppStringKeys.countryAD, 'AD', '376'),
    Country(AppStringKeys.countryMC, 'MC', '377'),
    Country(AppStringKeys.countrySM, 'SM', '378'),
    Country(AppStringKeys.countryLI, 'LI', '423'),
    // Africa
    Country(AppStringKeys.countryEG, 'EG', '20'),
    Country(AppStringKeys.countryZA, 'ZA', '27'),
    Country(AppStringKeys.countryMA, 'MA', '212'),
    Country(AppStringKeys.countryDZ, 'DZ', '213'),
    Country(AppStringKeys.countryTN, 'TN', '216'),
    Country(AppStringKeys.countryLY, 'LY', '218'),
    Country(AppStringKeys.countryNG, 'NG', '234'),
    Country(AppStringKeys.countryGH, 'GH', '233'),
    Country(AppStringKeys.countryCI, 'CI', '225'),
    Country(AppStringKeys.countrySN, 'SN', '221'),
    Country(AppStringKeys.countryCM, 'CM', '237'),
    Country(AppStringKeys.countryKE, 'KE', '254'),
    Country(AppStringKeys.countryET, 'ET', '251'),
    Country(AppStringKeys.countryTZ, 'TZ', '255'),
    Country(AppStringKeys.countryUG, 'UG', '256'),
    Country(AppStringKeys.countryZM, 'ZM', '260'),
    Country(AppStringKeys.countryZW, 'ZW', '263'),
    Country(AppStringKeys.countryAO, 'AO', '244'),
    Country(AppStringKeys.countryMZ, 'MZ', '258'),
    Country(AppStringKeys.countryBW, 'BW', '267'),
    Country(AppStringKeys.countryNA, 'NA', '264'),
    Country(AppStringKeys.countryRW, 'RW', '250'),
    Country(AppStringKeys.countryML, 'ML', '223'),
    Country(AppStringKeys.countryBF, 'BF', '226'),
    Country(AppStringKeys.countryNE, 'NE', '227'),
    Country(AppStringKeys.countryTD, 'TD', '235'),
    Country(AppStringKeys.countrySD, 'SD', '249'),
    Country(AppStringKeys.countrySS, 'SS', '211'),
    Country(AppStringKeys.countrySO, 'SO', '252'),
    Country(AppStringKeys.countryMG, 'MG', '261'),
    Country(AppStringKeys.countryMW, 'MW', '265'),
    Country(AppStringKeys.countryGA, 'GA', '241'),
    Country(AppStringKeys.countryCG, 'CG', '242'),
    Country(AppStringKeys.countryCD, 'CD', '243'),
    Country(AppStringKeys.countryBJ, 'BJ', '229'),
    Country(AppStringKeys.countryTG, 'TG', '228'),
    Country(AppStringKeys.countryGN, 'GN', '224'),
    Country(AppStringKeys.countryMR, 'MR', '222'),
    Country(AppStringKeys.countryMU, 'MU', '230'),
    // North & Central America
    Country(AppStringKeys.countryUS, 'US', '1'),
    Country(AppStringKeys.countryCA, 'CA', '1'),
    Country(AppStringKeys.countryMX, 'MX', '52'),
    Country(AppStringKeys.countryGT, 'GT', '502'),
    Country(AppStringKeys.countryBZ, 'BZ', '501'),
    Country(AppStringKeys.countrySV, 'SV', '503'),
    Country(AppStringKeys.countryHN, 'HN', '504'),
    Country(AppStringKeys.countryNI, 'NI', '505'),
    Country(AppStringKeys.countryCR, 'CR', '506'),
    Country(AppStringKeys.countryPA, 'PA', '507'),
    Country(AppStringKeys.countryCU, 'CU', '53'),
    Country(AppStringKeys.countryHT, 'HT', '509'),
    // South America
    Country(AppStringKeys.countryBR, 'BR', '55'),
    Country(AppStringKeys.countryAR, 'AR', '54'),
    Country(AppStringKeys.countryCL, 'CL', '56'),
    Country(AppStringKeys.countryCO, 'CO', '57'),
    Country(AppStringKeys.countryPE, 'PE', '51'),
    Country(AppStringKeys.countryVE, 'VE', '58'),
    Country(AppStringKeys.countryEC, 'EC', '593'),
    Country(AppStringKeys.countryBO, 'BO', '591'),
    Country(AppStringKeys.countryPY, 'PY', '595'),
    Country(AppStringKeys.countryUY, 'UY', '598'),
    Country(AppStringKeys.countryGY, 'GY', '592'),
    Country(AppStringKeys.countrySR, 'SR', '597'),
    // Oceania
    Country(AppStringKeys.countryAU, 'AU', '61'),
    Country(AppStringKeys.countryNZ, 'NZ', '64'),
    Country(AppStringKeys.countryFJ, 'FJ', '679'),
    Country(AppStringKeys.countryPG, 'PG', '675'),
    Country(AppStringKeys.countryWS, 'WS', '685'),
    Country(AppStringKeys.countryTO, 'TO', '676'),
    Country(AppStringKeys.countryVU, 'VU', '678'),
    Country(AppStringKeys.countrySB, 'SB', '677'),
    // Remaining geographical regions from the bundled libphonenumber metadata.
    Country(AppStringKeys.countryAC, 'AC', '247'),
    Country(AppStringKeys.countryAG, 'AG', '1'),
    Country(AppStringKeys.countryAI, 'AI', '1'),
    Country(AppStringKeys.countryAS, 'AS', '1'),
    Country(AppStringKeys.countryAW, 'AW', '297'),
    Country(AppStringKeys.countryAX, 'AX', '358'),
    Country(AppStringKeys.countryBB, 'BB', '1'),
    Country(AppStringKeys.countryBI, 'BI', '257'),
    Country(AppStringKeys.countryBL, 'BL', '590'),
    Country(AppStringKeys.countryBM, 'BM', '1'),
    Country(AppStringKeys.countryBQ, 'BQ', '599'),
    Country(AppStringKeys.countryBS, 'BS', '1'),
    Country(AppStringKeys.countryCC, 'CC', '61'),
    Country(AppStringKeys.countryCF, 'CF', '236'),
    Country(AppStringKeys.countryCK, 'CK', '682'),
    Country(AppStringKeys.countryCV, 'CV', '238'),
    Country(AppStringKeys.countryCW, 'CW', '599'),
    Country(AppStringKeys.countryCX, 'CX', '61'),
    Country(AppStringKeys.countryDJ, 'DJ', '253'),
    Country(AppStringKeys.countryDM, 'DM', '1'),
    Country(AppStringKeys.countryDO, 'DO', '1'),
    Country(AppStringKeys.countryEH, 'EH', '212'),
    Country(AppStringKeys.countryER, 'ER', '291'),
    Country(AppStringKeys.countryFK, 'FK', '500'),
    Country(AppStringKeys.countryFM, 'FM', '691'),
    Country(AppStringKeys.countryFO, 'FO', '298'),
    Country(AppStringKeys.countryGD, 'GD', '1'),
    Country(AppStringKeys.countryGF, 'GF', '594'),
    Country(AppStringKeys.countryGG, 'GG', '44'),
    Country(AppStringKeys.countryGI, 'GI', '350'),
    Country(AppStringKeys.countryGL, 'GL', '299'),
    Country(AppStringKeys.countryGM, 'GM', '220'),
    Country(AppStringKeys.countryGP, 'GP', '590'),
    Country(AppStringKeys.countryGQ, 'GQ', '240'),
    Country(AppStringKeys.countryGU, 'GU', '1'),
    Country(AppStringKeys.countryGW, 'GW', '245'),
    Country(AppStringKeys.countryIM, 'IM', '44'),
    Country(AppStringKeys.countryIO, 'IO', '246'),
    Country(AppStringKeys.countryJE, 'JE', '44'),
    Country(AppStringKeys.countryJM, 'JM', '1'),
    Country(AppStringKeys.countryKI, 'KI', '686'),
    Country(AppStringKeys.countryKM, 'KM', '269'),
    Country(AppStringKeys.countryKN, 'KN', '1'),
    Country(AppStringKeys.countryKY, 'KY', '1'),
    Country(AppStringKeys.countryLC, 'LC', '1'),
    Country(AppStringKeys.countryLR, 'LR', '231'),
    Country(AppStringKeys.countryLS, 'LS', '266'),
    Country(AppStringKeys.countryMF, 'MF', '590'),
    Country(AppStringKeys.countryMH, 'MH', '692'),
    Country(AppStringKeys.countryMP, 'MP', '1'),
    Country(AppStringKeys.countryMQ, 'MQ', '596'),
    Country(AppStringKeys.countryMS, 'MS', '1'),
    Country(AppStringKeys.countryNC, 'NC', '687'),
    Country(AppStringKeys.countryNF, 'NF', '672'),
    Country(AppStringKeys.countryNR, 'NR', '674'),
    Country(AppStringKeys.countryNU, 'NU', '683'),
    Country(AppStringKeys.countryPF, 'PF', '689'),
    Country(AppStringKeys.countryPM, 'PM', '508'),
    Country(AppStringKeys.countryPR, 'PR', '1'),
    Country(AppStringKeys.countryPW, 'PW', '680'),
    Country(AppStringKeys.countryRE, 'RE', '262'),
    Country(AppStringKeys.countrySC, 'SC', '248'),
    Country(AppStringKeys.countrySH, 'SH', '290'),
    Country(AppStringKeys.countrySJ, 'SJ', '47'),
    Country(AppStringKeys.countrySL, 'SL', '232'),
    Country(AppStringKeys.countryST, 'ST', '239'),
    Country(AppStringKeys.countrySX, 'SX', '1'),
    Country(AppStringKeys.countrySZ, 'SZ', '268'),
    Country(AppStringKeys.countryTA, 'TA', '290'),
    Country(AppStringKeys.countryTC, 'TC', '1'),
    Country(AppStringKeys.countryTK, 'TK', '690'),
    Country(AppStringKeys.countryTT, 'TT', '1'),
    Country(AppStringKeys.countryTV, 'TV', '688'),
    Country(AppStringKeys.countryVA, 'VA', '39'),
    Country(AppStringKeys.countryVC, 'VC', '1'),
    Country(AppStringKeys.countryVG, 'VG', '1'),
    Country(AppStringKeys.countryVI, 'VI', '1'),
    Country(AppStringKeys.countryWF, 'WF', '681'),
    Country(AppStringKeys.countryYT, 'YT', '262'),
  ];

  /// `all`, sorted by localized display name for presentation.
  static List<Country> get sorted =>
      [...all]
        ..sort((a, b) => AppStrings.t(a.name).compareTo(AppStrings.t(b.name)));

  /// Best country whose dial code is a prefix of [digits].
  ///
  /// Longest dial wins. Shared codes use libphonenumber's leading-digit
  /// metadata, which matches Telegram's country detection behavior for ranges
  /// such as +76/+77 Kazakhstan under the shared +7 country code.
  static const _mainForCode = {
    '1': 'US',
    '7': 'RU',
    '39': 'IT',
    '44': 'GB',
    '47': 'NO',
    '61': 'AU',
    '86': 'CN',
    '212': 'MA',
    '262': 'RE',
    '290': 'SH',
    '358': 'FI',
    '590': 'GP',
    '599': 'CW',
  };

  static Country? match(String digits) {
    if (digits.isEmpty) return null;
    final candidates = all
        .where((c) => c.dial.isNotEmpty && digits.startsWith(c.dial))
        .toList();
    if (candidates.isEmpty) return null;
    final maxLen = candidates
        .map((c) => c.dial.length)
        .reduce((a, b) => a > b ? a : b);
    final best = candidates.where((c) => c.dial.length == maxLen).toList();
    if (best.length == 1) return best.first;
    final metadataMatch = _matchSharedCodeFromPhoneMetadata(digits, best);
    if (metadataMatch != null) return metadataMatch;
    final main = _mainForCode[best.first.dial];
    return best.firstWhere((c) => c.iso == main, orElse: () => best.first);
  }

  static Country? _matchSharedCodeFromPhoneMetadata(
    String digits,
    List<Country> candidates,
  ) {
    if (candidates.isEmpty || digits.length <= candidates.first.dial.length) {
      return null;
    }
    try {
      final parsed = PhoneNumberUtil.instance.parse('+$digits', null);
      final region = PhoneNumberUtil.instance.getRegionCodeForNumber(parsed);
      final match = _byIso(region, candidates);
      if (match != null) return match;
    } catch (_) {
      // Keep login typing resilient; fall through to short-prefix metadata.
    }

    // libphonenumber metadata marks Kazakhstan under +7 with national prefixes
    // 6 and 7. Keep this explicit so the UI flips to KZ immediately at "+77",
    // even if parsing rejects the very short partial number on some platforms.
    if (digits.startsWith('76') || digits.startsWith('77')) {
      return _byIso('KZ', candidates);
    }
    return null;
  }

  static Country? _byIso(String? iso, [Iterable<Country>? scope]) {
    if (iso == null || iso.isEmpty) return null;
    final upper = iso.toUpperCase();
    for (final country in scope ?? all) {
      if (country.iso == upper) return country;
    }
    return null;
  }
}

class CountryPickerView extends StatefulWidget {
  const CountryPickerView({super.key, required this.onSelect});
  final ValueChanged<Country> onSelect;

  @override
  State<CountryPickerView> createState() => _CountryPickerViewState();
}

class _CountryPickerViewState extends State<CountryPickerView> {
  final _controller = TextEditingController();
  Map<String, String> _telegramNames = TelegramCountryNames.shared.cached;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadTelegramCountryNames());
  }

  Future<void> _loadTelegramCountryNames() async {
    try {
      final names = await TelegramCountryNames.shared.load(refresh: true);
      if (mounted && names.isNotEmpty) {
        setState(() => _telegramNames = names);
      }
    } catch (_) {
      // The bundled names remain available before authorization or offline.
    }
  }

  String _displayName(Country country) => country.displayName(_telegramNames);

  List<Country> get _sortedCountries =>
      [...Country.all]
        ..sort((a, b) => _displayName(a).compareTo(_displayName(b)));

  List<Country> get _results {
    final q = _query.trim();
    if (q.isEmpty) return _sortedCountries;
    final lower = q.toLowerCase();
    final digits = q.replaceAll(RegExp(r'[^0-9]'), '');
    return _sortedCountries.where((c) {
      final name = _displayName(c).toLowerCase();
      return name.contains(lower) ||
          c.iso.toLowerCase().contains(lower) ||
          (digits.isNotEmpty && c.dial.contains(digits));
    }).toList();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        backgroundColor: c.navBar,
        title: Text(
          AppStringKeys.countryPickerSelectCountryOrRegion.l10n(context),
          style: TextStyle(fontSize: 17, color: c.textPrimary),
        ),
        centerTitle: true,
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            AppStringKeys.countryPickerCancel.l10n(context),
            style: TextStyle(color: AppTheme.brand),
          ),
        ),
        leadingWidth: 64,
      ),
      body: Column(
        children: [
          Container(
            color: c.background,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: c.searchFill,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Row(
                children: [
                  AppIcon(
                    HeroAppIcons.magnifyingGlass,
                    size: 18,
                    color: c.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      onChanged: (v) => setState(() => _query = v),
                      style: TextStyle(color: c.textPrimary, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: AppStringKeys.countryPickerSearchPlaceholder
                            .l10n(context),
                        border: InputBorder.none,
                        isCollapsed: true,
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    GestureDetector(
                      onTap: () => setState(() {
                        _controller.clear();
                        _query = '';
                      }),
                      child: AppIcon(
                        HeroAppIcons.xmark,
                        size: 18,
                        color: c.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Container(
              color: c.background,
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, i) {
                  final country = _results[i];
                  return InkWell(
                    onTap: () {
                      widget.onSelect(country);
                      Navigator.of(context).pop();
                    },
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          CountryFlag(iso: country.iso),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _displayName(country),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 17,
                                color: c.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '+${country.dial}',
                            style: TextStyle(
                              fontSize: 16,
                              color: c.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
