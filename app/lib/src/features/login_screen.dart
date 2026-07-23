import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../controller.dart';
import '../defaults.dart';
import '../theme.dart';
import 'locale_controller.dart';

/// Localizes a server error by its stable code where a generic message is clearly
/// right (rate-limited, locked, timeout…); otherwise returns the server's own
/// message, which for auth ("wrong email or password") beats a coarse code.
String localizeApiError(
  AppLocalizations l10n, {
  String? code,
  String? message,
}) => switch (code) {
  'rate_limited' => l10n.errorRateLimited,
  'account_locked' => l10n.errorAccountLocked,
  'payload_too_large' => l10n.errorPayloadTooLarge,
  'internal_error' => l10n.errorInternal,
  'timeout' => l10n.errorTimeout,
  'forbidden' => l10n.errorForbidden,
  _ => message ?? l10n.genericError,
};

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  // Prefilled: a blank field is unanswerable on a first run — nothing on screen
  // says what a "server" is here, and submitting empty fails as "network error".
  // Still editable, because self-hosting is the point of the field.
  final _server = TextEditingController(text: kDefaultServerUrl);
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = true;
  bool _busy = false;

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final ok = await ref
        .read(controllerProvider.notifier)
        .authenticate(
          serverUrl: _server.text.trim(),
          email: _email.text.trim(),
          password: _password.text,
          register: _register,
        );
    if (mounted) setState(() => _busy = false);
    if (!ok && mounted) {
      final s = ref.read(controllerProvider);
      final err = localizeApiError(
        AppLocalizations.of(context),
        code: s.errorCode,
        message: s.error,
      );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerRight,
                    child: _LanguageMenu(),
                  ),
                  Text(
                    'Aul',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.appTagline,
                    style: const TextStyle(
                      color: AulColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                        value: true,
                        label: Text(l10n.loginCreateAccount),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text(l10n.loginSignIn),
                      ),
                    ],
                    selected: {_register},
                    onSelectionChanged: (s) =>
                        setState(() => _register = s.first),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.loginServerLabel,
                      hintText: l10n.loginServerHint,
                      // helperText, not just hintText: Material hides the hint
                      // behind the label while the field is unfocused, so the
                      // explanation was invisible exactly when it was needed.
                      helperText: l10n.loginServerHelp,
                      helperMaxLines: 2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.loginEmailLabel,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l10n.loginPasswordLabel,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _register
                                ? l10n.loginCreateAccount
                                : l10n.loginSignIn,
                          ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.loginKeyReassurance,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AulColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Language picker for the signed-out screens. The full picker lives in About,
/// but that screen is reachable only AFTER signing in — so anyone whose device
/// language resolved to the wrong one had no way to change it while still
/// looking at the login form.
class _LanguageMenu extends ConsumerWidget {
  const _LanguageMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // "system" as a sentinel rather than null: PopupMenuButton treats a null
    // selection as a dismissal and never calls onSelected, so a nullable value
    // would silently make the "System" entry do nothing.
    final current =
        ref.watch(localeControllerProvider)?.languageCode ?? 'system';

    return PopupMenuButton<String>(
      icon: const Icon(Icons.language),
      tooltip: l10n.language,
      initialValue: current,
      onSelected: (v) => ref
          .read(localeControllerProvider.notifier)
          .setLocale(v == 'system' ? null : Locale(v)),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'system',
          checked: current == 'system',
          child: Text(l10n.languageSystem),
        ),
        CheckedPopupMenuItem(
          value: 'en',
          checked: current == 'en',
          child: Text(l10n.languageEnglish),
        ),
        CheckedPopupMenuItem(
          value: 'ru',
          checked: current == 'ru',
          child: Text(l10n.languageRussian),
        ),
      ],
    );
  }
}
