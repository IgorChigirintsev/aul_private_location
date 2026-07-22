import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../domain/location_fix.dart';

/// The Precise / City / Paused control, in one place because it now appears
/// twice: on the home screen (acting on the selected circle) and on every
/// circles-dashboard row (acting on that row's circle). Both write the SAME
/// per-circle server value, so they must offer the same three choices and read
/// the same way.
///
/// [onChanged] is null while a write is in flight, which disables the control
/// rather than letting a second tap race the first.
class PrecisionSegmented extends StatelessWidget {
  const PrecisionSegmented({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final PrecisionMode value;
  final ValueChanged<PrecisionMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SegmentedButton<PrecisionMode>(
      segments: [
        ButtonSegment(
          value: PrecisionMode.precise,
          label: Text(l10n.precisionPrecise),
        ),
        ButtonSegment(
          value: PrecisionMode.city,
          label: Text(l10n.precisionCity),
        ),
        ButtonSegment(
          value: PrecisionMode.paused,
          label: Text(l10n.precisionPaused),
        ),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: onChanged == null ? null : (v) => onChanged!(v.first),
    );
  }
}

/// What a circle actually SEES at [mode], in plain words — the line under the
/// control. Says it from the circle's point of view ("this circle sees…"),
/// because that is the question the user is answering.
String precisionDescription(AppLocalizations l10n, PrecisionMode mode) =>
    switch (mode) {
      PrecisionMode.precise => l10n.circlesDashPrecisionPrecise,
      PrecisionMode.city => l10n.circlesDashPrecisionCity,
      PrecisionMode.paused => l10n.circlesDashPrecisionPaused,
    };
