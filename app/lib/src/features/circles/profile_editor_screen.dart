import 'dart:convert';
import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../data/api/models.dart';
import '../../theme.dart';
import 'members_screen.dart' show decodeAvatarDataUrl;

/// The cropped avatar is downscaled to this square so a member's picture stays
/// tiny inside the sealed blob regardless of the source photo's size.
const int _avatarPx = 128;

/// Client-side guard well under the server's sealed-profile size limit. The
/// avatar data URL dominates the sealed bytes, so guarding it keeps the PUT small.
const int _maxProfileBytes = 100 * 1024;

/// Edits the caller's OWN per-circle profile: a nickname (shown instead of the
/// email) and a self-cropped avatar. Everything is sealed under the circle key by
/// [AppController.saveProfile] before it leaves the device — the server only ever
/// relays ciphertext. Pre-fills from the current profile (matched by email).
class ProfileEditorScreen extends ConsumerStatefulWidget {
  const ProfileEditorScreen({super.key, required this.circleId});

  final String circleId;

  @override
  ConsumerState<ProfileEditorScreen> createState() =>
      _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends ConsumerState<ProfileEditorScreen> {
  final _nick = TextEditingController();

  /// The current avatar as a "data:image/jpeg;base64,…" data URL, or null.
  String? _avatar;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  @override
  void dispose() {
    _nick.dispose();
    super.dispose();
  }

  /// Pre-fills the editor from the caller's existing profile in this circle,
  /// found by matching the session email against the member list.
  Future<void> _loadInitial() async {
    final ctrl = ref.read(controllerProvider.notifier);
    final email = ref.read(controllerProvider).email;
    try {
      final members = await ctrl.membersOf(widget.circleId);
      Member? me;
      for (final m in members) {
        if (email != null && m.email == email) {
          me = m;
          break;
        }
      }
      final profile = me == null
          ? null
          : await ctrl.openMemberProfile(widget.circleId, me.profileEnc);
      if (!mounted) return;
      setState(() {
        _nick.text = profile?.nick ?? '';
        _avatar = profile?.avatar;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _choosePhoto() async {
    final l10n = AppLocalizations.of(context);
    Uint8List bytes;
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null) return;
      bytes = await file.readAsBytes();
    } catch (_) {
      if (mounted) setState(() => _error = l10n.profileImageError);
      return;
    }
    if (!mounted) return;
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => _CropAvatarScreen(bytes: bytes)),
    );
    if (cropped == null) return;
    final dataUrl = await _toAvatarDataUrl(cropped);
    if (!mounted) return;
    setState(() {
      if (dataUrl == null) {
        _error = l10n.profileImageError;
      } else {
        _avatar = dataUrl;
        _error = null;
      }
    });
  }

  /// Downscales the cropped bytes to a [_avatarPx]² JPEG and encodes a data URL.
  /// Pure Dart (package:image) so it's verifiable without native plugins.
  Future<String?> _toAvatarDataUrl(Uint8List bytes) async {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final resized = img.copyResize(
        decoded,
        width: _avatarPx,
        height: _avatarPx,
        interpolation: img.Interpolation.average,
      );
      final jpg = img.encodeJpg(resized, quality: 85);
      return 'data:image/jpeg;base64,${base64.encode(jpg)}';
    } catch (_) {
      return null;
    }
  }

  void _removePhoto() => setState(() {
    _avatar = null;
    _error = null;
  });

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final avatar = _avatar;
    if (avatar != null && avatar.length > _maxProfileBytes) {
      setState(() => _error = l10n.profileTooLarge);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref
          .read(controllerProvider.notifier)
          .saveProfile(
            widget.circleId,
            nick: _nick.text.trim(),
            avatar: avatar,
          );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(l10n.profileSaved)));
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = l10n.profileSaveError;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.editProfile)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  l10n.profileTitle,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 20),
                Center(child: _avatarPreview(context)),
                const SizedBox(height: 12),
                Center(
                  child: Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _choosePhoto,
                        icon: const Icon(Icons.photo_outlined),
                        label: Text(
                          _avatar == null
                              ? l10n.profileChoosePhoto
                              : l10n.profileChangePhoto,
                        ),
                      ),
                      if (_avatar != null)
                        TextButton(
                          onPressed: _saving ? null : _removePhoto,
                          style: TextButton.styleFrom(
                            foregroundColor: AulColors.danger,
                          ),
                          child: Text(l10n.profileRemovePhoto),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.profileNickname,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _nick,
                  maxLength: 40,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: l10n.profileNicknameHint,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(color: AulColors.danger),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.save),
                ),
              ],
            ),
    );
  }

  Widget _avatarPreview(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final bytes = decodeAvatarDataUrl(_avatar);
    if (bytes != null) {
      return CircleAvatar(radius: 48, backgroundImage: MemoryImage(bytes));
    }
    final nick = _nick.text.trim();
    final initial = nick.isEmpty ? '?' : nick[0].toUpperCase();
    return CircleAvatar(
      radius: 48,
      backgroundColor: primary.withValues(alpha: 0.12),
      child: Text(
        initial,
        style: TextStyle(
          color: primary,
          fontSize: 32,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Full-screen square/circle cropper for a freshly picked photo. Returns the
/// cropped image bytes via [Navigator.pop], or null if cancelled/failed.
class _CropAvatarScreen extends StatefulWidget {
  const _CropAvatarScreen({required this.bytes});
  final Uint8List bytes;

  @override
  State<_CropAvatarScreen> createState() => _CropAvatarScreenState();
}

class _CropAvatarScreenState extends State<_CropAvatarScreen> {
  final _controller = CropController();
  bool _cropping = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(l10n.cropTitle),
        actions: [
          TextButton(
            onPressed: _cropping
                ? null
                : () {
                    setState(() => _cropping = true);
                    _controller.crop();
                  },
            child: Text(l10n.done),
          ),
        ],
      ),
      body: Crop(
        image: widget.bytes,
        controller: _controller,
        aspectRatio: 1,
        withCircleUi: true,
        baseColor: Colors.black,
        maskColor: Colors.black.withValues(alpha: 0.6),
        onCropped: (result) {
          if (!mounted) return;
          switch (result) {
            case CropSuccess(:final croppedImage):
              Navigator.of(context).pop(croppedImage);
            case CropFailure():
              Navigator.of(context).pop();
          }
        },
      ),
    );
  }
}
