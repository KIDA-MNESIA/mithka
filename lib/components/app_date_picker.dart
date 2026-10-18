import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'app_icons.dart';
import 'app_interactive_surface.dart';

/// Project-owned calendar for picking a day — the search bar's "jump to date"
/// sheet. The framework's Material/Cupertino pickers are deliberately not used;
/// the grid, chrome and gestures here are app-owned like every other surface.
///
/// Resolves the picked day (local midnight) or null when dismissed. Days
/// before [firstDate] or after [lastDate] render dimmed and inert.
Future<DateTime?> showAppDatePicker(
  BuildContext context, {
  required String title,
  DateTime? initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
}) {
  final now = DateTime.now();
  return showGeneralDialog<DateTime>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppStrings.t(AppStringKeys.confirmCancel),
    barrierColor: const Color(0xFF000000).withValues(alpha: 0.52),
    transitionDuration: AppMotion.duration(context, AppMotion.responsive),
    transitionBuilder: AppMotion.dialogTransition,
    pageBuilder: (dialogContext, _, _) => _AppDatePickerDialog(
      title: title,
      initialDate: initialDate ?? now,
      firstDate: firstDate ?? DateTime(2009, 8),
      lastDate: lastDate ?? now,
    ),
  );
}

class _AppDatePickerDialog extends StatefulWidget {
  const _AppDatePickerDialog({
    required this.title,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final String title;
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_AppDatePickerDialog> createState() => _AppDatePickerDialogState();
}

class _AppDatePickerDialogState extends State<_AppDatePickerDialog> {
  late DateTime _shownMonth;
  DateTime? _selectedDate;

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    final first = _dateOnly(widget.firstDate);
    final last = _dateOnly(widget.lastDate);
    var seed = _dateOnly(widget.initialDate);
    if (seed.isBefore(first)) seed = first;
    if (seed.isAfter(last)) seed = last;
    _shownMonth = DateTime(seed.year, seed.month);
    _selectedDate = _inRange(seed) ? seed : null;
  }

  bool _inRange(DateTime day) {
    final normalized = _dateOnly(day);
    final first = _dateOnly(widget.firstDate);
    final last = _dateOnly(widget.lastDate);
    return !normalized.isBefore(first) && !normalized.isAfter(last);
  }

  DateTime? get _validSelectedDate {
    final selected = _selectedDate;
    if (selected == null) return null;
    final normalized = _dateOnly(selected);
    if (normalized.year != _shownMonth.year ||
        normalized.month != _shownMonth.month) {
      return null;
    }
    return _inRange(normalized) ? normalized : null;
  }

  void _shift(int months) {
    setState(() {
      final nextMonth = DateTime(_shownMonth.year, _shownMonth.month + months);
      _shownMonth = nextMonth;
      final selected = _selectedDate;
      if (selected != null) {
        final daysInNext = DateTime(nextMonth.year, nextMonth.month + 1, 0).day;
        final clampedDay = selected.day <= daysInNext
            ? selected.day
            : daysInNext;
        final candidate = DateTime(nextMonth.year, nextMonth.month, clampedDay);
        _selectedDate = _inRange(candidate) ? candidate : null;
      }
    });
  }

  void _confirm() {
    final target = _validSelectedDate;
    if (target == null) return;
    Navigator.of(context).pop(target);
  }

  List<String> _weekdayLabels(BuildContext context) {
    final locale = Localizations.maybeLocaleOf(context)?.toLanguageTag();
    try {
      final formatter = DateFormat.E(locale);
      final monday = DateTime.utc(2024); // 2024-01-01 is a Monday.
      return [
        for (var day = 0; day < 7; day++)
          formatter.format(monday.add(Duration(days: day))),
      ];
    } catch (_) {
      return [
        AppStrings.t(AppStringKeys.businessSettingsMonday),
        AppStrings.t(AppStringKeys.businessSettingsTuesday),
        AppStrings.t(AppStringKeys.businessSettingsWednesday),
        AppStrings.t(AppStringKeys.businessSettingsThursday),
        AppStrings.t(AppStringKeys.businessSettingsFriday),
        AppStrings.t(AppStringKeys.businessSettingsSaturday),
        AppStrings.t(AppStringKeys.businessSettingsSunday),
      ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cancel = AppStrings.t(AppStringKeys.confirmCancel);
    final ok = AppStrings.t(AppStringKeys.confirmOk);
    final weekdays = _weekdayLabels(context);
    return AppDialogSurface(
      title: widget.title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _MonthChevron(
                key: const ValueKey('appDatePickerPrevMonth'),
                icon: HeroAppIcons.chevronLeft,
                onTap: () => _shift(-1),
              ),
              Expanded(
                child: Text(
                  '${_shownMonth.year} · ${_shownMonth.month}',
                  textAlign: TextAlign.center,
                  style: AppTextStyle.bodyLarge(
                    c.dialogText,
                    weight: AppTextWeight.semibold,
                  ),
                ),
              ),
              _MonthChevron(
                key: const ValueKey('appDatePickerNextMonth'),
                icon: HeroAppIcons.chevronRight,
                onTap: () => _shift(1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final label in weekdays)
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    textAlign: TextAlign.center,
                    style: AppTextStyle.caption(c.textTertiary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _buildGrid(c),
        ],
      ),
      actions: [
        AppDialogAction(
          label: cancel,
          onTap: () => Navigator.of(context).pop(),
        ),
        AppDialogAction(
          key: const ValueKey('appDatePickerConfirm'),
          label: ok,
          primary: true,
          onTap: _confirm,
        ),
      ],
    );
  }

  Widget _buildGrid(AppColors c) {
    final first = DateTime(_shownMonth.year, _shownMonth.month);
    final leadingBlanks = first.weekday - 1; // Monday-first grid.
    final dayCount = DateTime(_shownMonth.year, _shownMonth.month + 1, 0).day;
    final validSelected = _validSelectedDate;
    final rows = <Widget>[];
    var cells = <Widget>[];
    for (var i = 0; i < leadingBlanks; i++) {
      cells.add(const Expanded(child: SizedBox.shrink()));
    }
    for (var day = 1; day <= dayCount; day++) {
      final date = DateTime(_shownMonth.year, _shownMonth.month, day);
      final enabled = _inRange(date);
      final selected =
          enabled && validSelected != null && validSelected.day == day;
      cells.add(
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? () => setState(() => _selectedDate = date) : null,
            child: SizedBox.square(
              dimension: 34,
              child: Center(
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? AppTheme.brand : null,
                  ),
                  child: Text(
                    '$day',
                    style: AppTextStyle.bodyLarge(
                      selected
                          ? const Color(0xFFFFFFFF)
                          : enabled
                          ? c.dialogText
                          : c.textTertiary.withValues(alpha: 0.4),
                      weight: selected ? AppTextWeight.semibold : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (cells.length == 7) {
        rows.add(Row(children: cells));
        cells = <Widget>[];
      }
    }
    if (cells.isNotEmpty) {
      while (cells.length < 7) {
        cells.add(const Expanded(child: SizedBox.shrink()));
      }
      rows.add(Row(children: cells));
    }
    return Column(children: rows);
  }
}

class _MonthChevron extends StatelessWidget {
  const _MonthChevron({super.key, required this.icon, required this.onTap});

  final AppIconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppInteractiveSurface(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox.square(
        dimension: 30,
        child: Center(
          child: AppIcon(icon, size: AppIconSize.xs, color: c.textSecondary),
        ),
      ),
    );
  }
}
