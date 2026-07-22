import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../crypto/safety_code.dart';
import '../../theme.dart';

/// One verifiable device: the owning member's display [label] (nickname if set,
/// else email), the device [platform], and the [code] two people compare out of
/// band (both phones independently derive the SAME code from BOTH identity keys).
class VerifyEntry {
  const VerifyEntry({
    required this.label,
    required this.platform,
    required this.code,
  });
  final String label;
  final String platform;
  final SafetyCode code;
}

/// Lists the OTHER members' devices in a circle and, for each, the safety code
/// this device shares with it. Two people read their code aloud in person: if it
/// matches on both phones, no server-injected man-in-the-middle has substituted
/// keys — the code is derived purely from the two identity public keys, never
/// sent to the server. This is the app equivalent of the web verification screen.
///
/// This device itself and any device without a published public key are excluded
/// (there is nothing to compare against those).
class VerifyDevicesScreen extends ConsumerStatefulWidget {
  const VerifyDevicesScreen({super.key, required this.circleId});

  final String circleId;

  @override
  ConsumerState<VerifyDevicesScreen> createState() =>
      _VerifyDevicesScreenState();
}

class _VerifyDevicesScreenState extends ConsumerState<VerifyDevicesScreen> {
  late Future<List<VerifyEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<VerifyEntry>> _load() async {
    final ctrl = ref.read(controllerProvider.notifier);
    final myPub = await ctrl.myIdentityPublicKey();
    if (myPub == null) throw StateError('no identity');
    final myDeviceId = await ctrl.myDeviceId();
    final devices = await ctrl.devicesOf(widget.circleId);

    // Member labels (nickname → email fallback), decrypted on device with K_c.
    final members = await ctrl.membersOf(widget.circleId);
    final labels = <String, String>{};
    for (final m in members) {
      final profile = await ctrl.openMemberProfile(
        widget.circleId,
        m.profileEnc,
      );
      final nick = profile?.nick.trim() ?? '';
      labels[m.userId] = nick.isNotEmpty ? nick : m.email;
    }

    final entries = <VerifyEntry>[];
    for (final d in devices) {
      final pub = d.pubkeyB64;
      if (pub == null) continue; // no key published → nothing to compare
      if (myDeviceId != null && d.id == myDeviceId) continue; // this device
      Uint8List theirPub;
      try {
        theirPub = base64.decode(pub);
      } catch (_) {
        continue;
      }
      if (theirPub.length != SafetyCode.publicKeyLength) continue;
      // A record carrying our OWN key (e.g. this device before it had a device
      // id) has nothing to verify against — skip it too.
      if (_bytesEqual(theirPub, myPub)) continue;
      entries.add(
        VerifyEntry(
          label: labels[d.userId] ?? d.userId,
          platform: d.platform,
          code: SafetyCode.compute(myPub, theirPub),
        ),
      );
    }
    entries.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return entries;
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _future = next);
    try {
      await next;
    } catch (_) {
      /* surfaced by the builder */
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.verifyDevicesTitle)),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<VerifyEntry>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _centeredMessage(l10n.verifyDevicesError);
            }
            final entries = snap.data ?? const <VerifyEntry>[];
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  l10n.verifyDevicesIntro,
                  style: const TextStyle(color: AulColors.textSecondary),
                ),
                const SizedBox(height: 16),
                if (entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Text(
                      l10n.verifyDevicesEmpty,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AulColors.textSecondary),
                    ),
                  )
                else
                  for (final e in entries) ...[
                    _VerifyCard(entry: e),
                    const SizedBox(height: 12),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// A scrollable centered message so pull-to-refresh still works on error.
  Widget _centeredMessage(String text) => ListView(
    padding: const EdgeInsets.all(32),
    children: [
      const SizedBox(height: 80),
      Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AulColors.textSecondary),
      ),
    ],
  );
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _VerifyCard extends StatelessWidget {
  const _VerifyCard({required this.entry});

  final VerifyEntry entry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                Text(
                  entry.platform,
                  style: const TextStyle(
                    color: AulColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // The emoji sequence — the primary thing to read aloud.
            Text(
              entry.code.display,
              style: const TextStyle(fontSize: 26, letterSpacing: 2),
            ),
            const SizedBox(height: 8),
            // The short hex digest — an accessible alternative to the emoji.
            Text(
              entry.code.hexFallback,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: AulColors.textSecondary,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
