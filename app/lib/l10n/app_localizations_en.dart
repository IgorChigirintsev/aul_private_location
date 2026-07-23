// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get onboardingNotifTitle => 'A visible, honest notification';

  @override
  String get onboardingNotifBody =>
      'While you share, Aul always shows a notification — there is no hidden mode. You can pause any time. Allow notifications so you always know when sharing is on.';

  @override
  String get onboardingNotifCta => 'Allow notifications';

  @override
  String get onboardingLocationTitle => 'Location while using the app';

  @override
  String get onboardingLocationBody =>
      'Aul needs your location to share it — encrypted — with your circle. Only your circle can decrypt it; the server sees ciphertext.';

  @override
  String get onboardingLocationCta => 'Allow location';

  @override
  String get onboardingBackgroundTitle => 'Keep sharing in your pocket';

  @override
  String get onboardingBackgroundBody =>
      'To keep your family updated when the app is closed, choose “Allow all the time” on the next screen. You stay in control and can stop instantly.';

  @override
  String get onboardingBackgroundCta => 'Allow in background';

  @override
  String get onboardingBatteryTitle => 'Don’t let the system sleep sharing';

  @override
  String get onboardingBatteryBody =>
      'Some phones aggressively stop background apps. Excluding Aul from battery optimization keeps location up to date (it still uses very little battery).';

  @override
  String get onboardingBatteryCta => 'Finish setup';

  @override
  String get onboardingSkip => 'Skip for now';

  @override
  String get appTagline =>
      'Private family location, end-to-end encrypted. We never see where you are — check the code.';

  @override
  String get loginCreateAccount => 'Create account';

  @override
  String get loginSignIn => 'Sign in';

  @override
  String get loginServerLabel => 'Server';

  @override
  String get loginServerHint => 'https://your-aul-server';

  @override
  String get loginServerHelp =>
      'Aul\'s public server. Change it only if you host your own.';

  @override
  String get loginEmailLabel => 'Email';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginKeyReassurance =>
      'Your location key never leaves your device. The server stores only ciphertext.';

  @override
  String get genericError => 'Something went wrong';

  @override
  String get whoCanSeeMe => 'Who can see me';

  @override
  String get aboutTitle => 'About & updates';

  @override
  String get debugTitle => 'Battery & debug';

  @override
  String get signOut => 'Sign out';

  @override
  String get homeSharingFooter =>
      'Sharing always shows a notification. You can stop instantly.';

  @override
  String get sosSentSuccess => 'SOS sent — sharing live with your circles';

  @override
  String get sosSentFailure =>
      'Couldn’t send SOS (no circle key on this device)';

  @override
  String get whoCanSeeMeNobody => 'You are not sharing with anyone yet.';

  @override
  String whoCanSeeMeCircles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count circles',
      one: '1 circle',
    );
    return 'Your encrypted location is shared with $_temp0. Only their members can decrypt it — the server cannot.';
  }

  @override
  String get joinCircleTitle => 'Join a circle';

  @override
  String get joinCircleHint => 'Paste your invite link';

  @override
  String get cancel => 'Cancel';

  @override
  String get join => 'Join';

  @override
  String get joinedCircle => 'Joined circle';

  @override
  String get couldNotJoin => 'Could not join';

  @override
  String get sharingOn => 'Sharing your location';

  @override
  String get sharingOff => 'Not sharing';

  @override
  String get precisionPrecise => 'Precise';

  @override
  String get precisionCity => 'City';

  @override
  String get precisionPaused => 'Paused';

  @override
  String get stopSharing => 'Stop sharing';

  @override
  String get startSharing => 'Start sharing';

  @override
  String get joinCircleFirst => 'Join a circle first to start sharing.';

  @override
  String get sosActiveBanner => 'SOS active — sharing live with your circles';

  @override
  String get errorRateLimited =>
      'Too many attempts. Please wait a moment and try again.';

  @override
  String get errorAccountLocked =>
      'Too many attempts — this account is temporarily locked. Try again later.';

  @override
  String get errorPayloadTooLarge => 'That’s too large to send.';

  @override
  String get errorInternal =>
      'Something went wrong on our end. Please try again.';

  @override
  String get errorTimeout => 'The request timed out. Please try again.';

  @override
  String get errorForbidden => 'You don’t have permission to do that.';

  @override
  String sosInOtherCircle(String names) {
    return 'SOS in $names — tap to open';
  }

  @override
  String get noCirclesYet => 'No circles yet';

  @override
  String circlesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count circles',
      one: '1 circle',
    );
    return '$_temp0';
  }

  @override
  String get joinByLink => 'Join by link';

  @override
  String get sosSendTitle => 'Send SOS?';

  @override
  String get sosSendBody =>
      'This alerts everyone in your circles and starts live sharing until you resolve it.';

  @override
  String get sosSend => 'Send SOS';

  @override
  String get sosHold => 'Hold for SOS';

  @override
  String get sosSemantic => 'SOS. Long press to send an emergency alert.';

  @override
  String get aboutTagline => 'Private family location, end-to-end encrypted.';

  @override
  String get aboutVersionLabel => 'Version';

  @override
  String aboutVersionValue(String versionName, int versionCode) {
    return '$versionName (build $versionCode)';
  }

  @override
  String get aboutVersionUnknown => 'unknown';

  @override
  String get updatesManagedByStore =>
      'Updates for this platform are managed by your app store.';

  @override
  String get updateUpToDate => 'You are on the latest version.';

  @override
  String get updateCheckError => 'Could not check for updates.';

  @override
  String get updateCheckPrompt => 'Check whether a newer build is available.';

  @override
  String get updateCheckButton => 'Check for updates';

  @override
  String get locationExtras => 'Location extras';

  @override
  String get locationExtrasSubtitle =>
      'Optional, private, and off by default. Everything here is computed on your device — the server never sees more.';

  @override
  String get serverDisabledFeatures =>
      'Your server has turned these features off.';

  @override
  String get arrivalAlertsTitle => 'Arrival alerts';

  @override
  String get arrivalAlertsSubtitle =>
      'Notify me when I arrive at or leave a saved place.';

  @override
  String get trackingRemindersTitle => 'Tracking reminders';

  @override
  String get trackingRemindersSubtitle =>
      'Remind me if sharing stops or battery is low.';

  @override
  String get themeLabel => 'Theme';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'System';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageRussian => 'Русский';

  @override
  String get debugSharing => 'Sharing';

  @override
  String get debugOn => 'On';

  @override
  String get debugOff => 'Off';

  @override
  String get debugPrecision => 'Precision';

  @override
  String get debugCircles => 'Circles';

  @override
  String get debugQueuedPings => 'Queued (unsent) pings';

  @override
  String get debugServer => 'Server';

  @override
  String get debugCadenceInfo =>
      'Adaptive cadence keeps battery low: still → 10 min, walking → 60 s, driving → 15 s, live/SOS → 5 s. Pings are batched and retried with backoff. Target: ≤ 3 % battery per day.';

  @override
  String get updateProblem => 'Update problem';

  @override
  String get updateAvailable => 'Update available';

  @override
  String get updateGenericError => 'Something went wrong.';

  @override
  String updateReadyToInstall(String versionName) {
    return 'Aul $versionName is ready to install.';
  }

  @override
  String get updateDownloading => 'Downloading & verifying…';

  @override
  String get updateInstalling => 'Starting installer…';

  @override
  String get later => 'Later';

  @override
  String get tryAgain => 'Try again';

  @override
  String get updateNow => 'Update now';

  @override
  String get updateCheckFailedRetry =>
      'Could not check for updates. Please try again.';

  @override
  String get updateNeedInstallPermission =>
      'Allow \"install unknown apps\" for Aul to update.';

  @override
  String get updateIntegrityFailed => 'Update aborted: integrity check failed.';

  @override
  String get updateDownloadFailed => 'Download failed. Please try again.';

  @override
  String get pushAlertsTitle => 'Notifications while Aul is closed';

  @override
  String get pushAlertsSubtitle =>
      'Let your circle\'s notifications reach this device in the background. They are decrypted on your phone — the server only relays them, and cannot read them.';

  @override
  String get notifChannelName => 'Aul reminders';

  @override
  String get notifChannelDescription =>
      'Arrival alerts, tracking reminders, and your weekly summary.';

  @override
  String get notifArrivedTitle => 'Arrived';

  @override
  String get notifLeftTitle => 'Left';

  @override
  String notifArrivedBody(String place) {
    return 'You arrived at $place';
  }

  @override
  String notifLeftBody(String place) {
    return 'You left $place';
  }

  @override
  String get notifCircleUpdateTitle => 'Circle update';

  @override
  String notifMemberArrivedBody(String name, String place) {
    return '$name arrived at $place';
  }

  @override
  String notifMemberLeftBody(String name, String place) {
    return '$name left $place';
  }

  @override
  String get notifSharingOffTitle => 'Sharing is off';

  @override
  String get notifSharingOffBody =>
      'Location sharing has stopped. Open Aul to resume.';

  @override
  String get notifBatteryLowTitle => 'Battery low';

  @override
  String get notifBatteryLowBody =>
      'Low battery may be affecting location sharing.';

  @override
  String sharingNotification(String label, String precision) {
    return 'Sharing with $label · $precision';
  }

  @override
  String sosNotification(String label) {
    return 'SOS active · sharing live with $label';
  }

  @override
  String get inviteInvalid => 'Not a valid invite link';

  @override
  String get inviteMissingKey => 'Invite link is missing the circle key';

  @override
  String get inviteMalformed => 'Invite key is malformed';

  @override
  String get inviteTitle => 'Invite to your circle';

  @override
  String get inviteSubtitle => 'Share a link that lets someone join';

  @override
  String get inviteCreating => 'Creating invite…';

  @override
  String get inviteError => 'Could not create an invite';

  @override
  String get inviteNote =>
      'This link contains your circle key in the part after “#”, which the server never receives. Anyone with the whole link can join this circle — share it only with family.';

  @override
  String get close => 'Close';

  @override
  String get circleFallback => 'Your circle';

  @override
  String get circlesYours => 'Your circles';

  @override
  String get circleOwnerBadge => 'owner';

  @override
  String get circleRoleMember => 'member';

  @override
  String get switchCircle => 'Switch circle';

  @override
  String get renameCircle => 'Rename circle';

  @override
  String get renameCircleHint => 'New circle name';

  @override
  String get rename => 'Rename';

  @override
  String get leaveCircle => 'Leave circle';

  @override
  String get leaveCircleTitle => 'Leave circle?';

  @override
  String get leaveCircleBody =>
      'Leave this circle? You’ll stop sharing your location with it and stop seeing its members.';

  @override
  String get leave => 'Leave';

  @override
  String get soleOwnerTitle => 'Delete this circle?';

  @override
  String get soleOwnerBody =>
      'You’re the only owner, so you can’t just leave. Delete this circle for everyone instead?';

  @override
  String get deleteCircle => 'Delete circle';

  @override
  String get deleteCircleTitle => 'Delete circle?';

  @override
  String deleteCircleBody(String name) {
    return 'Delete “$name” for everyone? This permanently removes the circle and all its data. This cannot be undone.';
  }

  @override
  String get delete => 'Delete';

  @override
  String get createCircle => 'New circle';

  @override
  String get createCircleHint => 'Name your circle';

  @override
  String get create => 'Create';

  @override
  String get circleRenamed => 'Circle renamed';

  @override
  String get circleLeft => 'You left the circle';

  @override
  String get circleDeleted => 'Circle deleted';

  @override
  String get circleCreated => 'Circle created';

  @override
  String get circleActionFailed => 'Something went wrong. Please try again.';

  @override
  String get membersTitle => 'People';

  @override
  String get membersEmpty => 'No one here yet. Invite your family with a link.';

  @override
  String get membersError => 'Couldn’t load members. Pull to try again.';

  @override
  String get profileYou => '(you)';

  @override
  String get verifyDevicesTitle => 'Verify devices';

  @override
  String get verifyDevicesIntro =>
      'Compare these codes out loud with each person. If they match on both phones, no one has swapped your encryption keys. The server never sees the codes.';

  @override
  String get verifyDevicesEmpty =>
      'No other devices to verify yet. They appear here once someone else joins this circle.';

  @override
  String get verifyDevicesError => 'Couldn’t load devices. Pull to try again.';

  @override
  String get rotateKey => 'Rotate circle key';

  @override
  String get rotateKeyTitle => 'Rotate circle key?';

  @override
  String get rotateKeyBody =>
      'This creates a new encryption key for the circle. New locations, places and alerts use the new key, and it is sent — sealed — to every member’s device. Existing data stays readable. Do this if you think the old key may have leaked.';

  @override
  String get rotateKeyConfirm => 'Rotate key';

  @override
  String get rotateKeySuccess => 'Circle key rotated';

  @override
  String get rotateKeyFailure => 'Couldn’t rotate the key. Please try again.';

  @override
  String get editProfile => 'Edit profile';

  @override
  String get profileTitle => 'Your profile in this circle';

  @override
  String get profileNickname => 'Nickname';

  @override
  String get profileNicknameHint => 'How you appear to this circle';

  @override
  String get profilePhoto => 'Photo';

  @override
  String get profileChoosePhoto => 'Choose photo';

  @override
  String get profileChangePhoto => 'Change photo';

  @override
  String get profileRemovePhoto => 'Remove photo';

  @override
  String get save => 'Save';

  @override
  String get profileSaved => 'Profile saved';

  @override
  String get profileTooLarge => 'That image is too large. Try a smaller crop.';

  @override
  String get profileImageError => 'Couldn’t read that image. Try another.';

  @override
  String get profileSaveError => 'Couldn’t save your profile. Try again.';

  @override
  String get cropTitle => 'Crop photo';

  @override
  String get done => 'Done';

  @override
  String get mapTitle => 'Map';

  @override
  String get mapRecenter => 'Recenter';

  @override
  String get mapNorthUp => 'Reset north';

  @override
  String get mapRecenterOnMe => 'Center on me';

  @override
  String get mapEmpty =>
      'No one to show yet. When your circle shares their location, they’ll appear on the map.';

  @override
  String get mapTagPc => 'PC';

  @override
  String get mapTagPhone => 'Phone';

  @override
  String get placesTitle => 'Places';

  @override
  String get geofenceFeedTitle => 'At places';

  @override
  String geofenceAtPlacesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people at places',
      one: '1 person at a place',
      zero: 'Nobody at a place',
    );
    return '$_temp0';
  }

  @override
  String get geofenceNobody => 'Nobody is inside a place right now.';

  @override
  String geofencePresenceRow(String name, String place) {
    return '$name is at $place';
  }

  @override
  String get geofenceRecent => 'Recent';

  @override
  String geofenceEventEnter(String name, String place) {
    return '$name arrived at $place';
  }

  @override
  String geofenceEventExit(String name, String place) {
    return '$name left $place';
  }

  @override
  String get geofenceOnTheWay => 'On the way';

  @override
  String geofenceEtaRow(String name, String place) {
    return '$name → $place';
  }

  @override
  String get geofenceEtaLessMin => '<1 min';

  @override
  String geofenceEtaMin(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count min',
      one: '1 min',
    );
    return '$_temp0';
  }

  @override
  String geofenceEtaHourMin(int h, int rem) {
    return '$h h $rem min';
  }

  @override
  String geofenceEtaHour(int h) {
    return '$h h';
  }

  @override
  String membersAccuracy(String value, String unit) {
    return '±$value $unit';
  }

  @override
  String get unitMeters => 'm';

  @override
  String get unitKilometers => 'km';

  @override
  String get placesAddAPlace => 'Add a place';

  @override
  String get placesNameHint => 'Place name (e.g. Home)';

  @override
  String get placesRadiusLabel => 'Geofence radius';

  @override
  String placesRadiusValue(int meters) {
    return '$meters m';
  }

  @override
  String get placesTapMap => 'Tap the map to set the centre.';

  @override
  String get placesCentreSet => 'Centre set. Adjust the radius, then save.';

  @override
  String get placesAddPlace => 'Add place';

  @override
  String get placesSaveChanges => 'Save changes';

  @override
  String get placesEmpty => 'No places yet. Add Home, Work, School…';

  @override
  String placesConfirmDelete(String name) {
    return 'Delete place “$name”?';
  }

  @override
  String get placesSaveFailed => 'Couldn’t save place. Please try again.';

  @override
  String get sosCenterTitle => 'SOS';

  @override
  String get sosCenterNoMessage => 'Emergency alert';

  @override
  String get sosCenterEncrypted => 'SOS raised — can’t decrypt on this device';

  @override
  String get sosCenterResolve => 'Resolve';

  @override
  String get membersRemove => 'Remove from circle';

  @override
  String get membersRemoveTitle => 'Remove member?';

  @override
  String get membersRemoveAction => 'Remove';

  @override
  String membersRemoveConfirm(String name) {
    return 'Remove $name from this circle? They stop seeing everyone, and stop sharing with you.';
  }

  @override
  String get membersRemoveFailed => 'Couldn’t remove them. Please try again.';

  @override
  String get membersRotateAfterRemove =>
      'They still hold the old circle key, so they could read data sent from now on. Rotate the circle key?';

  @override
  String get shareTitle => 'Live share link';

  @override
  String get shareHomeHint =>
      'Show where you are to one person, without an account — for as long as you choose.';

  @override
  String get shareIntro =>
      'Creates a link that shows your live location to one person — no account needed. Whoever opens it first keeps it; nobody else can. It stops at the deadline, or the moment you revoke it.';

  @override
  String get shareDuration => 'How long';

  @override
  String get shareCreate => 'Create link';

  @override
  String get shareCreating => 'Creating…';

  @override
  String get shareError => 'Could not create a share link';

  @override
  String get shareLinkTitle => 'Your share link';

  @override
  String get shareNote =>
      'The key that decrypts your position is the part after #, which the server never receives. Anyone holding the whole link can watch you until it ends.';

  @override
  String get shareActive => 'Active links';

  @override
  String get shareNone => 'No active share links.';

  @override
  String get shareClaimed => 'Open — a viewer has this link';

  @override
  String get shareUnclaimed =>
      'Not opened yet — the first device to open it keeps it';

  @override
  String get shareNoKeyHere =>
      'Made on another device: its link can’t be shown here, but you can still revoke it.';

  @override
  String get shareRevoke => 'Revoke';

  @override
  String get shareRevokeConfirm =>
      'Revoke this link? Whoever is watching stops seeing you immediately.';

  @override
  String get shareBannerSharing => 'Sharing your live location';

  @override
  String get shareNotification => 'Sharing your live location via a link';

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Copied';

  @override
  String get sosHoldHint => 'Hold the SOS button to send an alert.';

  @override
  String get sosNoKeyHint =>
      'No circle key on this device — an SOS can’t be sealed for anyone yet.';

  @override
  String shareMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String shareEndsIn(String countdown) {
    return 'Ends in $countdown';
  }

  @override
  String shareBannerSharingMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count links',
      one: '1 link',
    );
    return 'Sharing your live location · $_temp0';
  }

  @override
  String get circlesDashTitle => 'My circles';

  @override
  String get circlesDashSubtitle =>
      'Every circle you\'re in, and what you give each one.';

  @override
  String get circlesDashEmpty => 'You\'re not in any circle yet.';

  @override
  String circlesDashYouAs(String nick) {
    return 'You as $nick';
  }

  @override
  String get circlesDashYouNoNick => 'You (no nickname set here)';

  @override
  String get circlesDashNotificationsTitle => 'Notifications';

  @override
  String get circlesDashNotificationsOn =>
      'This circle\'s members can send you notifications.';

  @override
  String get circlesDashNotificationsOff =>
      'Muted — notifications from this circle\'s members don\'t reach you.';

  @override
  String get circlesDashActionFailed => 'Couldn\'t save that change.';

  @override
  String membersMute(String name) {
    return 'Mute $name — stop their notifications reaching you';
  }

  @override
  String membersUnmute(String name) {
    return 'Unmute $name — let their notifications reach you again';
  }

  @override
  String get membersMuteFailed => 'Couldn\'t change that mute.';

  @override
  String placesAddedBy(String name) {
    return 'Added by $name';
  }

  @override
  String get agoJustNow => 'just now';

  @override
  String agoMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count min ago',
      one: '1 min ago',
    );
    return '$_temp0';
  }

  @override
  String agoHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count h ago',
      one: '1 h ago',
    );
    return '$_temp0';
  }

  @override
  String batteryPercent(int pct) {
    return '$pct%';
  }

  @override
  String get batteryLabel => 'Battery';

  @override
  String get membersNoPosition => 'No location yet';

  @override
  String get staleBadge => 'Stale';

  @override
  String get liveUpdatesPaused => 'Live updates paused — reconnecting…';

  @override
  String connectionStale(String ago) {
    return 'Locations may be stale — last connected $ago';
  }

  @override
  String get circlesDashPrecisionTitle => 'What this circle sees';

  @override
  String get circlesDashPrecisionPrecise =>
      'This circle sees exactly where you are.';

  @override
  String get circlesDashPrecisionCity =>
      'This circle sees roughly which part of town you\'re in — not your exact spot.';

  @override
  String get circlesDashPrecisionPaused =>
      'Paused — your location isn\'t shared with this circle.';

  @override
  String homePrecisionFor(String circle) {
    return 'What $circle sees';
  }

  @override
  String get homePrecisionPerCircleHint =>
      'Each circle has its own setting. Change the others in My circles.';

  @override
  String get precisionChangeFailed =>
      'Couldn\'t change that. Please try again.';

  @override
  String get forkTitle => 'Get started';

  @override
  String get forkSubtitle =>
      'You\'re not in a circle yet. Choose how you\'d like to begin.';

  @override
  String get forkCreateTitle => 'Create a circle';

  @override
  String get forkCreateBody =>
      'Start a private circle on our server and invite your family with a link.';

  @override
  String get forkCreateCta => 'Create a circle';

  @override
  String get forkJoinTitle => 'Join a circle';

  @override
  String get forkJoinBody =>
      'Got an invite link? Paste it to join an existing circle.';

  @override
  String get forkJoinCta => 'Join with a link';

  @override
  String get forkSelfHostTitle => 'Run your own server';

  @override
  String get forkSelfHostBody =>
      'Run Aul on your own computer so your data never leaves your machine. It needs the computer kept on.';

  @override
  String get forkComingSoon => 'Coming soon';
}
