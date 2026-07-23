import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// Onboarding step 1 title — the notification-honesty step.
  ///
  /// In en, this message translates to:
  /// **'A visible, honest notification'**
  String get onboardingNotifTitle;

  /// Onboarding step 1 body explaining why notifications are requested.
  ///
  /// In en, this message translates to:
  /// **'While you share, Aul always shows a notification — there is no hidden mode. You can pause any time. Allow notifications so you always know when sharing is on.'**
  String get onboardingNotifBody;

  /// Onboarding step 1 primary button.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications'**
  String get onboardingNotifCta;

  /// Onboarding step 2 title — while-in-use location.
  ///
  /// In en, this message translates to:
  /// **'Location while using the app'**
  String get onboardingLocationTitle;

  /// Onboarding step 2 body.
  ///
  /// In en, this message translates to:
  /// **'Aul needs your location to share it — encrypted — with your circle. Only your circle can decrypt it; the server sees ciphertext.'**
  String get onboardingLocationBody;

  /// Onboarding step 2 primary button.
  ///
  /// In en, this message translates to:
  /// **'Allow location'**
  String get onboardingLocationCta;

  /// Onboarding step 3 title — background location.
  ///
  /// In en, this message translates to:
  /// **'Keep sharing in your pocket'**
  String get onboardingBackgroundTitle;

  /// Onboarding step 3 body.
  ///
  /// In en, this message translates to:
  /// **'To keep your family updated when the app is closed, choose “Allow all the time” on the next screen. You stay in control and can stop instantly.'**
  String get onboardingBackgroundBody;

  /// Onboarding step 3 primary button.
  ///
  /// In en, this message translates to:
  /// **'Allow in background'**
  String get onboardingBackgroundCta;

  /// Onboarding step 4 title — battery optimization exclusion.
  ///
  /// In en, this message translates to:
  /// **'Don’t let the system sleep sharing'**
  String get onboardingBatteryTitle;

  /// Onboarding step 4 body.
  ///
  /// In en, this message translates to:
  /// **'Some phones aggressively stop background apps. Excluding Aul from battery optimization keeps location up to date (it still uses very little battery).'**
  String get onboardingBatteryBody;

  /// Onboarding step 4 primary button that completes onboarding.
  ///
  /// In en, this message translates to:
  /// **'Finish setup'**
  String get onboardingBatteryCta;

  /// Onboarding skip link shown under the primary button.
  ///
  /// In en, this message translates to:
  /// **'Skip for now'**
  String get onboardingSkip;

  /// Marketing tagline shown under the app name on the login screen.
  ///
  /// In en, this message translates to:
  /// **'Private family location, end-to-end encrypted. We never see where you are — check the code.'**
  String get appTagline;

  /// Login segmented-button option and submit button for registering.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get loginCreateAccount;

  /// Login segmented-button option and submit button for signing in.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get loginSignIn;

  /// Text field label for the self-hosted server URL.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get loginServerLabel;

  /// Placeholder example for the server URL field.
  ///
  /// In en, this message translates to:
  /// **'https://your-aul-server'**
  String get loginServerHint;

  /// Always-visible helper under the server field, explaining the prefilled value.
  ///
  /// In en, this message translates to:
  /// **'Aul\'s public server. Change it only if you host your own.'**
  String get loginServerHelp;

  /// Text field label for the email address.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get loginEmailLabel;

  /// Text field label for the password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get loginPasswordLabel;

  /// Reassuring footnote under the login submit button.
  ///
  /// In en, this message translates to:
  /// **'Your location key never leaves your device. The server stores only ciphertext.'**
  String get loginKeyReassurance;

  /// Fallback error message when no specific error is available.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get genericError;

  /// Home app-bar tooltip and bottom-sheet title for the visibility summary.
  ///
  /// In en, this message translates to:
  /// **'Who can see me'**
  String get whoCanSeeMe;

  /// Title of the About screen; also the Home menu item that opens it.
  ///
  /// In en, this message translates to:
  /// **'About & updates'**
  String get aboutTitle;

  /// Title of the Debug screen; also the Home menu item that opens it.
  ///
  /// In en, this message translates to:
  /// **'Battery & debug'**
  String get debugTitle;

  /// Home menu item that signs the user out.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOut;

  /// Reassuring footer under the Home content.
  ///
  /// In en, this message translates to:
  /// **'Sharing always shows a notification. You can stop instantly.'**
  String get homeSharingFooter;

  /// Snackbar shown after an SOS is successfully raised.
  ///
  /// In en, this message translates to:
  /// **'SOS sent — sharing live with your circles'**
  String get sosSentSuccess;

  /// Snackbar shown when an SOS could not be sent.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t send SOS (no circle key on this device)'**
  String get sosSentFailure;

  /// Visibility bottom-sheet body when the user is in no circles.
  ///
  /// In en, this message translates to:
  /// **'You are not sharing with anyone yet.'**
  String get whoCanSeeMeNobody;

  /// Visibility bottom-sheet body when sharing with one or more circles.
  ///
  /// In en, this message translates to:
  /// **'Your encrypted location is shared with {count, plural, =1{1 circle} other{{count} circles}}. Only their members can decrypt it — the server cannot.'**
  String whoCanSeeMeCircles(int count);

  /// Title of the join-by-link dialog.
  ///
  /// In en, this message translates to:
  /// **'Join a circle'**
  String get joinCircleTitle;

  /// Placeholder in the invite-link text field.
  ///
  /// In en, this message translates to:
  /// **'Paste your invite link'**
  String get joinCircleHint;

  /// Generic cancel button.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Confirm button in the join-a-circle dialog.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get join;

  /// Snackbar shown after successfully joining a circle.
  ///
  /// In en, this message translates to:
  /// **'Joined circle'**
  String get joinedCircle;

  /// Snackbar shown when joining a circle failed.
  ///
  /// In en, this message translates to:
  /// **'Could not join'**
  String get couldNotJoin;

  /// Sharing card heading when sharing is active.
  ///
  /// In en, this message translates to:
  /// **'Sharing your location'**
  String get sharingOn;

  /// Sharing card heading when sharing is off.
  ///
  /// In en, this message translates to:
  /// **'Not sharing'**
  String get sharingOff;

  /// Precision option: exact coordinates.
  ///
  /// In en, this message translates to:
  /// **'Precise'**
  String get precisionPrecise;

  /// Precision option: coarsened to city granularity.
  ///
  /// In en, this message translates to:
  /// **'City'**
  String get precisionCity;

  /// Precision option: not sharing / paused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get precisionPaused;

  /// Button to stop sharing location.
  ///
  /// In en, this message translates to:
  /// **'Stop sharing'**
  String get stopSharing;

  /// Button to start sharing location.
  ///
  /// In en, this message translates to:
  /// **'Start sharing'**
  String get startSharing;

  /// Hint shown when there is no circle to share with yet.
  ///
  /// In en, this message translates to:
  /// **'Join a circle first to start sharing.'**
  String get joinCircleFirst;

  /// Banner shown on Home while an SOS is active.
  ///
  /// In en, this message translates to:
  /// **'SOS active — sharing live with your circles'**
  String get sosActiveBanner;

  /// No description provided for @errorRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Please wait a moment and try again.'**
  String get errorRateLimited;

  /// No description provided for @errorAccountLocked.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts — this account is temporarily locked. Try again later.'**
  String get errorAccountLocked;

  /// No description provided for @errorPayloadTooLarge.
  ///
  /// In en, this message translates to:
  /// **'That’s too large to send.'**
  String get errorPayloadTooLarge;

  /// No description provided for @errorInternal.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong on our end. Please try again.'**
  String get errorInternal;

  /// No description provided for @errorTimeout.
  ///
  /// In en, this message translates to:
  /// **'The request timed out. Please try again.'**
  String get errorTimeout;

  /// No description provided for @errorForbidden.
  ///
  /// In en, this message translates to:
  /// **'You don’t have permission to do that.'**
  String get errorForbidden;

  /// Red Home banner when a circle OTHER than the selected one has an active SOS. {names} is one or more circle names.
  ///
  /// In en, this message translates to:
  /// **'SOS in {names} — tap to open'**
  String sosInOtherCircle(String names);

  /// Circles card label when the user is in no circles.
  ///
  /// In en, this message translates to:
  /// **'No circles yet'**
  String get noCirclesYet;

  /// A count of circles, e.g. '1 circle' or '3 circles'.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 circle} other{{count} circles}}'**
  String circlesCount(int count);

  /// Circles card button to join a circle via an invite link.
  ///
  /// In en, this message translates to:
  /// **'Join by link'**
  String get joinByLink;

  /// Title of the SOS confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Send SOS?'**
  String get sosSendTitle;

  /// Body of the SOS confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'This alerts everyone in your circles and starts live sharing until you resolve it.'**
  String get sosSendBody;

  /// Confirm button that raises the SOS.
  ///
  /// In en, this message translates to:
  /// **'Send SOS'**
  String get sosSend;

  /// Caption inside the round SOS button.
  ///
  /// In en, this message translates to:
  /// **'Hold for SOS'**
  String get sosHold;

  /// Accessibility label for the SOS button.
  ///
  /// In en, this message translates to:
  /// **'SOS. Long press to send an emergency alert.'**
  String get sosSemantic;

  /// Tagline on the About card.
  ///
  /// In en, this message translates to:
  /// **'Private family location, end-to-end encrypted.'**
  String get aboutTagline;

  /// Row label for the installed app version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get aboutVersionLabel;

  /// Installed version, e.g. '1.0.0 (build 1)'.
  ///
  /// In en, this message translates to:
  /// **'{versionName} (build {versionCode})'**
  String aboutVersionValue(String versionName, int versionCode);

  /// Shown when the installed version cannot be read.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get aboutVersionUnknown;

  /// Shown when self-update is unavailable (e.g. iOS).
  ///
  /// In en, this message translates to:
  /// **'Updates for this platform are managed by your app store.'**
  String get updatesManagedByStore;

  /// Status line after a manual check finds no newer version.
  ///
  /// In en, this message translates to:
  /// **'You are on the latest version.'**
  String get updateUpToDate;

  /// Fallback status line when an update check errored.
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates.'**
  String get updateCheckError;

  /// Default prompt on the update-check card.
  ///
  /// In en, this message translates to:
  /// **'Check whether a newer build is available.'**
  String get updateCheckPrompt;

  /// Button that manually checks for updates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updateCheckButton;

  /// Heading of the optional retention-features section.
  ///
  /// In en, this message translates to:
  /// **'Location extras'**
  String get locationExtras;

  /// Subtitle of the retention-features section.
  ///
  /// In en, this message translates to:
  /// **'Optional, private, and off by default. Everything here is computed on your device — the server never sees more.'**
  String get locationExtrasSubtitle;

  /// Note shown when the server kill-switch disables the retention features.
  ///
  /// In en, this message translates to:
  /// **'Your server has turned these features off.'**
  String get serverDisabledFeatures;

  /// Toggle title for arrival/left notifications.
  ///
  /// In en, this message translates to:
  /// **'Arrival alerts'**
  String get arrivalAlertsTitle;

  /// Toggle subtitle for arrival alerts.
  ///
  /// In en, this message translates to:
  /// **'Notify me when I arrive at or leave a saved place.'**
  String get arrivalAlertsSubtitle;

  /// Toggle title for re-engagement reminders.
  ///
  /// In en, this message translates to:
  /// **'Tracking reminders'**
  String get trackingRemindersTitle;

  /// Toggle subtitle for tracking reminders.
  ///
  /// In en, this message translates to:
  /// **'Remind me if sharing stops or battery is low.'**
  String get trackingRemindersSubtitle;

  /// No description provided for @themeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get themeLabel;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// Heading of the language-picker section in About.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// Language option that follows the device language.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// Language option for English (shown in its own endonym).
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// Language option for Russian (shown in its own endonym; do not translate).
  ///
  /// In en, this message translates to:
  /// **'Русский'**
  String get languageRussian;

  /// Debug row label for the sharing on/off state.
  ///
  /// In en, this message translates to:
  /// **'Sharing'**
  String get debugSharing;

  /// Debug value: a feature is on.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get debugOn;

  /// Debug value: a feature is off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get debugOff;

  /// Debug row label for the current precision mode.
  ///
  /// In en, this message translates to:
  /// **'Precision'**
  String get debugPrecision;

  /// Debug row label for the number of circles.
  ///
  /// In en, this message translates to:
  /// **'Circles'**
  String get debugCircles;

  /// Debug row label for the offline queue depth.
  ///
  /// In en, this message translates to:
  /// **'Queued (unsent) pings'**
  String get debugQueuedPings;

  /// Debug row label for the signed-in server URL.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get debugServer;

  /// Explanatory card about the adaptive reporting cadence and battery target.
  ///
  /// In en, this message translates to:
  /// **'Adaptive cadence keeps battery low: still → 10 min, walking → 60 s, driving → 15 s, live/SOS → 5 s. Pings are batched and retried with backoff. Target: ≤ 3 % battery per day.'**
  String get debugCadenceInfo;

  /// Update card heading when an update failed.
  ///
  /// In en, this message translates to:
  /// **'Update problem'**
  String get updateProblem;

  /// Update card heading when a newer version is available.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get updateAvailable;

  /// Fallback error text in the update card.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong.'**
  String get updateGenericError;

  /// Update card line naming the version ready to install.
  ///
  /// In en, this message translates to:
  /// **'Aul {versionName} is ready to install.'**
  String updateReadyToInstall(String versionName);

  /// Update card status while the APK downloads and is verified.
  ///
  /// In en, this message translates to:
  /// **'Downloading & verifying…'**
  String get updateDownloading;

  /// Update card status while handing off to the system installer.
  ///
  /// In en, this message translates to:
  /// **'Starting installer…'**
  String get updateInstalling;

  /// Dismiss button on the update card.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get later;

  /// Retry button on the update card after an error.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get tryAgain;

  /// Primary button to start the update.
  ///
  /// In en, this message translates to:
  /// **'Update now'**
  String get updateNow;

  /// Error after a failed manual update check.
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates. Please try again.'**
  String get updateCheckFailedRetry;

  /// Error when the install-unknown-apps permission is missing.
  ///
  /// In en, this message translates to:
  /// **'Allow \"install unknown apps\" for Aul to update.'**
  String get updateNeedInstallPermission;

  /// Error when the downloaded APK failed its SHA-256 check.
  ///
  /// In en, this message translates to:
  /// **'Update aborted: integrity check failed.'**
  String get updateIntegrityFailed;

  /// Error when the update download failed.
  ///
  /// In en, this message translates to:
  /// **'Download failed. Please try again.'**
  String get updateDownloadFailed;

  /// Title of the switch opting this device into background push (FCM).
  ///
  /// In en, this message translates to:
  /// **'Notifications while Aul is closed'**
  String get pushAlertsTitle;

  /// Subtitle of the background push switch, stating the E2EE property.
  ///
  /// In en, this message translates to:
  /// **'Let your circle\'s notifications reach this device in the background. They are decrypted on your phone — the server only relays them, and cannot read them.'**
  String get pushAlertsSubtitle;

  /// Android notification channel name shown in system settings.
  ///
  /// In en, this message translates to:
  /// **'Aul reminders'**
  String get notifChannelName;

  /// Android notification channel description shown in system settings.
  ///
  /// In en, this message translates to:
  /// **'Arrival alerts, tracking reminders, and your weekly summary.'**
  String get notifChannelDescription;

  /// Notification title when the user enters a saved place.
  ///
  /// In en, this message translates to:
  /// **'Arrived'**
  String get notifArrivedTitle;

  /// Notification title when the user leaves a saved place.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get notifLeftTitle;

  /// Notification body when the user enters a saved place.
  ///
  /// In en, this message translates to:
  /// **'You arrived at {place}'**
  String notifArrivedBody(String place);

  /// Notification body when the user leaves a saved place.
  ///
  /// In en, this message translates to:
  /// **'You left {place}'**
  String notifLeftBody(String place);

  /// Notification title for a circle member's arrival.
  ///
  /// In en, this message translates to:
  /// **'Circle update'**
  String get notifCircleUpdateTitle;

  /// Notification body when a circle member arrives at a shared place.
  ///
  /// In en, this message translates to:
  /// **'{name} arrived at {place}'**
  String notifMemberArrivedBody(String name, String place);

  /// Notification body when a circle member leaves a shared place.
  ///
  /// In en, this message translates to:
  /// **'{name} left {place}'**
  String notifMemberLeftBody(String name, String place);

  /// Reminder notification title when sharing has stopped unexpectedly.
  ///
  /// In en, this message translates to:
  /// **'Sharing is off'**
  String get notifSharingOffTitle;

  /// Reminder notification body when sharing has stopped.
  ///
  /// In en, this message translates to:
  /// **'Location sharing has stopped. Open Aul to resume.'**
  String get notifSharingOffBody;

  /// Reminder notification title when the battery is low.
  ///
  /// In en, this message translates to:
  /// **'Battery low'**
  String get notifBatteryLowTitle;

  /// Reminder notification body when the battery is low.
  ///
  /// In en, this message translates to:
  /// **'Low battery may be affecting location sharing.'**
  String get notifBatteryLowBody;

  /// Persistent foreground-service notification text while sharing normally.
  ///
  /// In en, this message translates to:
  /// **'Sharing with {label} · {precision}'**
  String sharingNotification(String label, String precision);

  /// Persistent foreground-service notification text during an SOS.
  ///
  /// In en, this message translates to:
  /// **'SOS active · sharing live with {label}'**
  String sosNotification(String label);

  /// Error when a pasted invite link cannot be parsed.
  ///
  /// In en, this message translates to:
  /// **'Not a valid invite link'**
  String get inviteInvalid;

  /// Error when the invite link has no circle key fragment.
  ///
  /// In en, this message translates to:
  /// **'Invite link is missing the circle key'**
  String get inviteMissingKey;

  /// Error when the invite key is the wrong length/format.
  ///
  /// In en, this message translates to:
  /// **'Invite key is malformed'**
  String get inviteMalformed;

  /// Title of the invite action and of the invite-link dialog.
  ///
  /// In en, this message translates to:
  /// **'Invite to your circle'**
  String get inviteTitle;

  /// Subtitle of the Invite item on the circle switcher sheet.
  ///
  /// In en, this message translates to:
  /// **'Share a link that lets someone join'**
  String get inviteSubtitle;

  /// Shown in the invite dialog while the invite is being created.
  ///
  /// In en, this message translates to:
  /// **'Creating invite…'**
  String get inviteCreating;

  /// Shown in the invite dialog when the invite could not be created (offline, refused, or no circle key on this device).
  ///
  /// In en, this message translates to:
  /// **'Could not create an invite'**
  String get inviteError;

  /// Honest explanation under the invite link: the key rides in the fragment, and whoever holds the whole link can join.
  ///
  /// In en, this message translates to:
  /// **'This link contains your circle key in the part after “#”, which the server never receives. Anyone with the whole link can join this circle — share it only with family.'**
  String get inviteNote;

  /// Dismisses a dialog.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// Generic circle name shown when a circle has no decrypted name.
  ///
  /// In en, this message translates to:
  /// **'Your circle'**
  String get circleFallback;

  /// Header of the circle-switcher list of the user's circles.
  ///
  /// In en, this message translates to:
  /// **'Your circles'**
  String get circlesYours;

  /// Small badge marking a circle (or member) the user owns.
  ///
  /// In en, this message translates to:
  /// **'owner'**
  String get circleOwnerBadge;

  /// Role badge for a non-owner circle member.
  ///
  /// In en, this message translates to:
  /// **'member'**
  String get circleRoleMember;

  /// Tooltip/label for the app-bar circle switcher control.
  ///
  /// In en, this message translates to:
  /// **'Switch circle'**
  String get switchCircle;

  /// Circle-switcher action (owner) that renames the selected circle.
  ///
  /// In en, this message translates to:
  /// **'Rename circle'**
  String get renameCircle;

  /// Text-field hint in the rename-circle dialog.
  ///
  /// In en, this message translates to:
  /// **'New circle name'**
  String get renameCircleHint;

  /// Confirm button in the rename-circle dialog.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// Circle-switcher action that leaves the selected circle.
  ///
  /// In en, this message translates to:
  /// **'Leave circle'**
  String get leaveCircle;

  /// Title of the leave-circle confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Leave circle?'**
  String get leaveCircleTitle;

  /// Body of the leave-circle confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Leave this circle? You’ll stop sharing your location with it and stop seeing its members.'**
  String get leaveCircleBody;

  /// Confirm button in the leave-circle dialog.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leave;

  /// Title shown when a sole owner tries to leave and must delete instead.
  ///
  /// In en, this message translates to:
  /// **'Delete this circle?'**
  String get soleOwnerTitle;

  /// Body shown when a sole owner tries to leave and must delete instead.
  ///
  /// In en, this message translates to:
  /// **'You’re the only owner, so you can’t just leave. Delete this circle for everyone instead?'**
  String get soleOwnerBody;

  /// Circle-switcher action (owner) that permanently deletes the circle.
  ///
  /// In en, this message translates to:
  /// **'Delete circle'**
  String get deleteCircle;

  /// Title of the delete-circle confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete circle?'**
  String get deleteCircleTitle;

  /// Body of the delete-circle confirmation dialog, naming the circle.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}” for everyone? This permanently removes the circle and all its data. This cannot be undone.'**
  String deleteCircleBody(String name);

  /// Confirm button in the delete-circle dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// Circle-switcher action that creates a new circle.
  ///
  /// In en, this message translates to:
  /// **'New circle'**
  String get createCircle;

  /// Text-field hint in the create-circle dialog.
  ///
  /// In en, this message translates to:
  /// **'Name your circle'**
  String get createCircleHint;

  /// Confirm button in the create-circle dialog.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// Snackbar after a circle is renamed.
  ///
  /// In en, this message translates to:
  /// **'Circle renamed'**
  String get circleRenamed;

  /// Snackbar after leaving a circle.
  ///
  /// In en, this message translates to:
  /// **'You left the circle'**
  String get circleLeft;

  /// Snackbar after a circle is deleted.
  ///
  /// In en, this message translates to:
  /// **'Circle deleted'**
  String get circleDeleted;

  /// Snackbar after a new circle is created.
  ///
  /// In en, this message translates to:
  /// **'Circle created'**
  String get circleCreated;

  /// Snackbar when a circle-management action fails.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get circleActionFailed;

  /// Title of the members screen and its entry-point button.
  ///
  /// In en, this message translates to:
  /// **'People'**
  String get membersTitle;

  /// Empty state on the members screen.
  ///
  /// In en, this message translates to:
  /// **'No one here yet. Invite your family with a link.'**
  String get membersEmpty;

  /// Error state on the members screen when loading fails.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t load members. Pull to try again.'**
  String get membersError;

  /// Suffix marking the current user in the members list.
  ///
  /// In en, this message translates to:
  /// **'(you)'**
  String get profileYou;

  /// Title of the device-verification screen and its entry-point button/menu item.
  ///
  /// In en, this message translates to:
  /// **'Verify devices'**
  String get verifyDevicesTitle;

  /// Explanation at the top of the verify-devices screen: read the safety codes aloud out of band to detect a man-in-the-middle.
  ///
  /// In en, this message translates to:
  /// **'Compare these codes out loud with each person. If they match on both phones, no one has swapped your encryption keys. The server never sees the codes.'**
  String get verifyDevicesIntro;

  /// Empty state on the verify-devices screen when there are no other devices to compare against.
  ///
  /// In en, this message translates to:
  /// **'No other devices to verify yet. They appear here once someone else joins this circle.'**
  String get verifyDevicesEmpty;

  /// Error state on the verify-devices screen when loading fails (e.g. offline, or no identity key on this device).
  ///
  /// In en, this message translates to:
  /// **'Couldn’t load devices. Pull to try again.'**
  String get verifyDevicesError;

  /// Owner-only menu item that re-keys the circle.
  ///
  /// In en, this message translates to:
  /// **'Rotate circle key'**
  String get rotateKey;

  /// Title of the confirm dialog before rotating the circle key.
  ///
  /// In en, this message translates to:
  /// **'Rotate circle key?'**
  String get rotateKeyTitle;

  /// Body of the confirm dialog explaining what rotating the circle key does.
  ///
  /// In en, this message translates to:
  /// **'This creates a new encryption key for the circle. New locations, places and alerts use the new key, and it is sent — sealed — to every member’s device. Existing data stays readable. Do this if you think the old key may have leaked.'**
  String get rotateKeyBody;

  /// Confirm button that performs the circle key rotation.
  ///
  /// In en, this message translates to:
  /// **'Rotate key'**
  String get rotateKeyConfirm;

  /// Snackbar after the circle key is successfully rotated and distributed.
  ///
  /// In en, this message translates to:
  /// **'Circle key rotated'**
  String get rotateKeySuccess;

  /// Snackbar when rotating the circle key fails (offline, or no key held on this device).
  ///
  /// In en, this message translates to:
  /// **'Couldn’t rotate the key. Please try again.'**
  String get rotateKeyFailure;

  /// Entry-point button/title for editing the per-circle profile.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get editProfile;

  /// Heading on the profile editor screen.
  ///
  /// In en, this message translates to:
  /// **'Your profile in this circle'**
  String get profileTitle;

  /// Label for the nickname field in the profile editor.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get profileNickname;

  /// Hint for the nickname field in the profile editor.
  ///
  /// In en, this message translates to:
  /// **'How you appear to this circle'**
  String get profileNicknameHint;

  /// Label for the avatar section in the profile editor.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get profilePhoto;

  /// Button to pick an avatar photo from the gallery.
  ///
  /// In en, this message translates to:
  /// **'Choose photo'**
  String get profileChoosePhoto;

  /// Button to replace an already-chosen avatar photo.
  ///
  /// In en, this message translates to:
  /// **'Change photo'**
  String get profileChangePhoto;

  /// Button to remove the avatar photo.
  ///
  /// In en, this message translates to:
  /// **'Remove photo'**
  String get profileRemovePhoto;

  /// Save button in the profile editor.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Snackbar after the profile is saved.
  ///
  /// In en, this message translates to:
  /// **'Profile saved'**
  String get profileSaved;

  /// Error when the sealed profile would exceed the size limit.
  ///
  /// In en, this message translates to:
  /// **'That image is too large. Try a smaller crop.'**
  String get profileTooLarge;

  /// Error when a chosen image can't be read/processed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t read that image. Try another.'**
  String get profileImageError;

  /// Error when saving the profile fails.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t save your profile. Try again.'**
  String get profileSaveError;

  /// Title of the avatar cropping screen.
  ///
  /// In en, this message translates to:
  /// **'Crop photo'**
  String get cropTitle;

  /// Confirm button on the avatar cropping screen.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// Title of the live map screen and the Home entry that opens it.
  ///
  /// In en, this message translates to:
  /// **'Map'**
  String get mapTitle;

  /// Map app-bar action that refits the camera to all members.
  ///
  /// In en, this message translates to:
  /// **'Recenter'**
  String get mapRecenter;

  /// Tooltip / accessibility label for the on-map control that rotates the camera back to north-up (resets bearing and pitch to 0).
  ///
  /// In en, this message translates to:
  /// **'Reset north'**
  String get mapNorthUp;

  /// Tooltip / accessibility label for the on-map control that flies the camera to the current user's own latest shared position.
  ///
  /// In en, this message translates to:
  /// **'Center on me'**
  String get mapRecenterOnMe;

  /// Map empty state shown over the basemap when no positions decode.
  ///
  /// In en, this message translates to:
  /// **'No one to show yet. When your circle shares their location, they’ll appear on the map.'**
  String get mapEmpty;

  /// Marker tag for a web (computer) device on the map.
  ///
  /// In en, this message translates to:
  /// **'PC'**
  String get mapTagPc;

  /// Marker tag for a phone (android/ios) device on the map.
  ///
  /// In en, this message translates to:
  /// **'Phone'**
  String get mapTagPhone;

  /// Title of the places manager sheet and its map action.
  ///
  /// In en, this message translates to:
  /// **'Places'**
  String get placesTitle;

  /// Title of the geofence feed sheet: who is inside a place right now.
  ///
  /// In en, this message translates to:
  /// **'At places'**
  String get geofenceFeedTitle;

  /// Collapsed geofence feed pill: how many member devices are inside a place right now.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Nobody at a place} =1{1 person at a place} other{{count} people at places}}'**
  String geofenceAtPlacesCount(int count);

  /// Geofence feed empty state for the presence section.
  ///
  /// In en, this message translates to:
  /// **'Nobody is inside a place right now.'**
  String get geofenceNobody;

  /// One presence row: a member is currently inside a place.
  ///
  /// In en, this message translates to:
  /// **'{name} is at {place}'**
  String geofencePresenceRow(String name, String place);

  /// Section header above the recent arrive/depart events.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get geofenceRecent;

  /// A recent geofence enter event.
  ///
  /// In en, this message translates to:
  /// **'{name} arrived at {place}'**
  String geofenceEventEnter(String name, String place);

  /// A recent geofence exit event.
  ///
  /// In en, this message translates to:
  /// **'{name} left {place}'**
  String geofenceEventExit(String name, String place);

  /// Section header above the rough ETA rows for members moving toward a place.
  ///
  /// In en, this message translates to:
  /// **'On the way'**
  String get geofenceOnTheWay;

  /// One 'on the way' row: a moving member and the place they are heading toward.
  ///
  /// In en, this message translates to:
  /// **'{name} → {place}'**
  String geofenceEtaRow(String name, String place);

  /// Rough ETA under a minute.
  ///
  /// In en, this message translates to:
  /// **'<1 min'**
  String get geofenceEtaLessMin;

  /// Rough ETA in whole minutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 min} other{{count} min}}'**
  String geofenceEtaMin(int count);

  /// Rough ETA of an hour or more, with remaining minutes.
  ///
  /// In en, this message translates to:
  /// **'{h} h {rem} min'**
  String geofenceEtaHourMin(int h, int rem);

  /// Rough ETA of a whole number of hours.
  ///
  /// In en, this message translates to:
  /// **'{h} h'**
  String geofenceEtaHour(int h);

  /// A member's reported location uncertainty, e.g. '±40 m' or '±1.2 km'.
  ///
  /// In en, this message translates to:
  /// **'±{value} {unit}'**
  String membersAccuracy(String value, String unit);

  /// Distance unit abbreviation: metres.
  ///
  /// In en, this message translates to:
  /// **'m'**
  String get unitMeters;

  /// Distance unit abbreviation: kilometres.
  ///
  /// In en, this message translates to:
  /// **'km'**
  String get unitKilometers;

  /// Button that starts adding a new place.
  ///
  /// In en, this message translates to:
  /// **'Add a place'**
  String get placesAddAPlace;

  /// Placeholder in the place-name text field.
  ///
  /// In en, this message translates to:
  /// **'Place name (e.g. Home)'**
  String get placesNameHint;

  /// Label above the geofence-radius slider.
  ///
  /// In en, this message translates to:
  /// **'Geofence radius'**
  String get placesRadiusLabel;

  /// A geofence radius in metres, e.g. '150 m'.
  ///
  /// In en, this message translates to:
  /// **'{meters} m'**
  String placesRadiusValue(int meters);

  /// Hint shown in the editor before a centre is picked.
  ///
  /// In en, this message translates to:
  /// **'Tap the map to set the centre.'**
  String get placesTapMap;

  /// Hint shown in the editor once the centre is picked.
  ///
  /// In en, this message translates to:
  /// **'Centre set. Adjust the radius, then save.'**
  String get placesCentreSet;

  /// Save button when creating a new place.
  ///
  /// In en, this message translates to:
  /// **'Add place'**
  String get placesAddPlace;

  /// Save button when editing an existing place.
  ///
  /// In en, this message translates to:
  /// **'Save changes'**
  String get placesSaveChanges;

  /// Empty state in the places list.
  ///
  /// In en, this message translates to:
  /// **'No places yet. Add Home, Work, School…'**
  String get placesEmpty;

  /// Confirmation before deleting a place.
  ///
  /// In en, this message translates to:
  /// **'Delete place “{name}”?'**
  String placesConfirmDelete(String name);

  /// Snackbar when saving a place fails (e.g. a version clash).
  ///
  /// In en, this message translates to:
  /// **'Couldn’t save place. Please try again.'**
  String get placesSaveFailed;

  /// Heading of an active SOS alert banner in the SOS centre.
  ///
  /// In en, this message translates to:
  /// **'SOS'**
  String get sosCenterTitle;

  /// SOS banner text when the alert decrypted but carried no message.
  ///
  /// In en, this message translates to:
  /// **'Emergency alert'**
  String get sosCenterNoMessage;

  /// SOS banner text when the payload can't be decrypted (still surfaced so no emergency is missed).
  ///
  /// In en, this message translates to:
  /// **'SOS raised — can’t decrypt on this device'**
  String get sosCenterEncrypted;

  /// Button that resolves (clears) an active SOS alert for the circle.
  ///
  /// In en, this message translates to:
  /// **'Resolve'**
  String get sosCenterResolve;

  /// Tooltip on the owner-only remove-member button
  ///
  /// In en, this message translates to:
  /// **'Remove from circle'**
  String get membersRemove;

  /// Confirm dialog title for removing a member
  ///
  /// In en, this message translates to:
  /// **'Remove member?'**
  String get membersRemoveTitle;

  /// Confirm button label for removing a member
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get membersRemoveAction;

  /// Confirm body for removing a member
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from this circle? They stop seeing everyone, and stop sharing with you.'**
  String membersRemoveConfirm(String name);

  /// Snackbar when removing a member fails
  ///
  /// In en, this message translates to:
  /// **'Couldn’t remove them. Please try again.'**
  String get membersRemoveFailed;

  /// Offered right after removing a member: removal alone does not revoke K_c
  ///
  /// In en, this message translates to:
  /// **'They still hold the old circle key, so they could read data sent from now on. Rotate the circle key?'**
  String get membersRotateAfterRemove;

  /// Title of the live-share sheet: a link that shows your live location to one outsider.
  ///
  /// In en, this message translates to:
  /// **'Live share link'**
  String get shareTitle;

  /// One-line hint under the share action on the home screen.
  ///
  /// In en, this message translates to:
  /// **'Show where you are to one person, without an account — for as long as you choose.'**
  String get shareHomeHint;

  /// Honest explanation of what a live-share link does, shown at the top of the sheet.
  ///
  /// In en, this message translates to:
  /// **'Creates a link that shows your live location to one person — no account needed. Whoever opens it first keeps it; nobody else can. It stops at the deadline, or the moment you revoke it.'**
  String get shareIntro;

  /// Label above the share duration choices.
  ///
  /// In en, this message translates to:
  /// **'How long'**
  String get shareDuration;

  /// Button that creates a live-share link.
  ///
  /// In en, this message translates to:
  /// **'Create link'**
  String get shareCreate;

  /// Busy label on the create-link button.
  ///
  /// In en, this message translates to:
  /// **'Creating…'**
  String get shareCreating;

  /// Error shown when creating a share link failed.
  ///
  /// In en, this message translates to:
  /// **'Could not create a share link'**
  String get shareError;

  /// Title above the freshly created link.
  ///
  /// In en, this message translates to:
  /// **'Your share link'**
  String get shareLinkTitle;

  /// Explains that the link fragment is the decryption key.
  ///
  /// In en, this message translates to:
  /// **'The key that decrypts your position is the part after #, which the server never receives. Anyone holding the whole link can watch you until it ends.'**
  String get shareNote;

  /// Header of the list of running share links.
  ///
  /// In en, this message translates to:
  /// **'Active links'**
  String get shareActive;

  /// Shown when there are no running share links.
  ///
  /// In en, this message translates to:
  /// **'No active share links.'**
  String get shareNone;

  /// A share session that a viewer has already opened.
  ///
  /// In en, this message translates to:
  /// **'Open — a viewer has this link'**
  String get shareClaimed;

  /// A share session nobody has opened yet.
  ///
  /// In en, this message translates to:
  /// **'Not opened yet — the first device to open it keeps it'**
  String get shareUnclaimed;

  /// A share session whose K_share is not on this device.
  ///
  /// In en, this message translates to:
  /// **'Made on another device: its link can’t be shown here, but you can still revoke it.'**
  String get shareNoKeyHere;

  /// Button that kills a share link now.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get shareRevoke;

  /// Confirmation before revoking a share link.
  ///
  /// In en, this message translates to:
  /// **'Revoke this link? Whoever is watching stops seeing you immediately.'**
  String get shareRevokeConfirm;

  /// Home banner shown while exactly one live share is running.
  ///
  /// In en, this message translates to:
  /// **'Sharing your live location'**
  String get shareBannerSharing;

  /// Foreground-service notification text while only a live share (no circle) is running.
  ///
  /// In en, this message translates to:
  /// **'Sharing your live location via a link'**
  String get shareNotification;

  /// Button that copies a link to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// Confirmation that a link was copied to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// Snackbar shown when the SOS button is tapped instead of held.
  ///
  /// In en, this message translates to:
  /// **'Hold the SOS button to send an alert.'**
  String get sosHoldHint;

  /// Snackbar/tooltip explaining why the SOS button is disabled.
  ///
  /// In en, this message translates to:
  /// **'No circle key on this device — an SOS can’t be sealed for anyone yet.'**
  String get sosNoKeyHint;

  /// A share duration in minutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String shareMinutes(int minutes);

  /// Countdown until a share link expires, e.g. "Ends in 09:07".
  ///
  /// In en, this message translates to:
  /// **'Ends in {countdown}'**
  String shareEndsIn(String countdown);

  /// Home banner while more than one live share is running.
  ///
  /// In en, this message translates to:
  /// **'Sharing your live location · {count, plural, =1{1 link} other{{count} links}}'**
  String shareBannerSharingMany(int count);

  /// Title of the circles dashboard screen listing every circle you are in.
  ///
  /// In en, this message translates to:
  /// **'My circles'**
  String get circlesDashTitle;

  /// Subtitle under the circles dashboard title.
  ///
  /// In en, this message translates to:
  /// **'Every circle you\'re in, and what you give each one.'**
  String get circlesDashSubtitle;

  /// Empty state of the circles dashboard.
  ///
  /// In en, this message translates to:
  /// **'You\'re not in any circle yet.'**
  String get circlesDashEmpty;

  /// Secondary line on a dashboard row showing your nickname in that circle.
  ///
  /// In en, this message translates to:
  /// **'You as {nick}'**
  String circlesDashYouAs(String nick);

  /// Secondary line on a dashboard row when you set no nickname in that circle.
  ///
  /// In en, this message translates to:
  /// **'You (no nickname set here)'**
  String get circlesDashYouNoNick;

  /// Switch label: whether this circle's members can notify you.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get circlesDashNotificationsTitle;

  /// Description under the notifications switch when it is on.
  ///
  /// In en, this message translates to:
  /// **'This circle\'s members can send you notifications.'**
  String get circlesDashNotificationsOn;

  /// Description under the notifications switch when muted. States plainly that the server stops the notifications reaching you, rather than hiding them locally.
  ///
  /// In en, this message translates to:
  /// **'Muted — notifications from this circle\'s members don\'t reach you.'**
  String get circlesDashNotificationsOff;

  /// Snackbar when a dashboard switch could not be written to the server.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save that change.'**
  String get circlesDashActionFailed;

  /// Tooltip on the bell toggle of an unmuted member.
  ///
  /// In en, this message translates to:
  /// **'Mute {name} — stop their notifications reaching you'**
  String membersMute(String name);

  /// Tooltip on the bell-off toggle of a muted member.
  ///
  /// In en, this message translates to:
  /// **'Unmute {name} — let their notifications reach you again'**
  String membersUnmute(String name);

  /// Snackbar when writing the mute set failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t change that mute.'**
  String get membersMuteFailed;

  /// Secondary line under a place name naming the member who created it.
  ///
  /// In en, this message translates to:
  /// **'Added by {name}'**
  String placesAddedBy(String name);

  /// Relative time for a position updated less than a minute ago.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get agoJustNow;

  /// Relative time for a position updated a number of minutes ago.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 min ago} other{{count} min ago}}'**
  String agoMinutes(int count);

  /// Relative time for a position updated a number of hours ago.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 h ago} other{{count} h ago}}'**
  String agoHours(int count);

  /// A member's battery level. Digits and a percent sign — no words to translate.
  ///
  /// In en, this message translates to:
  /// **'{pct}%'**
  String batteryPercent(int pct);

  /// Accessibility label naming what the battery percentage on a member's row is.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get batteryLabel;

  /// Shown on a member's row when no decrypted position of theirs exists yet.
  ///
  /// In en, this message translates to:
  /// **'No location yet'**
  String get membersNoPosition;

  /// Badge on a member's row and a dimmed map marker whose latest position is older than the freshness threshold, so a last-known dot is never read as current.
  ///
  /// In en, this message translates to:
  /// **'Stale'**
  String get staleBadge;

  /// Non-alarming banner on Home and the map, shown when the realtime socket is down (server offline, network gone). Generic on purpose so it fits cloud and self-host alike.
  ///
  /// In en, this message translates to:
  /// **'Live updates paused — reconnecting…'**
  String get liveUpdatesPaused;

  /// Second line of the offline banner — how stale the map may be, as an age. {ago} is a localized relative time such as "14 min ago".
  ///
  /// In en, this message translates to:
  /// **'Locations may be stale — last connected {ago}'**
  String connectionStale(String ago);

  /// Label of the per-circle Precise/City/Paused control on the circles dashboard.
  ///
  /// In en, this message translates to:
  /// **'What this circle sees'**
  String get circlesDashPrecisionTitle;

  /// Description under the per-circle precision control when set to Precise.
  ///
  /// In en, this message translates to:
  /// **'This circle sees exactly where you are.'**
  String get circlesDashPrecisionPrecise;

  /// Description under the per-circle precision control when set to City.
  ///
  /// In en, this message translates to:
  /// **'This circle sees roughly which part of town you\'re in — not your exact spot.'**
  String get circlesDashPrecisionCity;

  /// Description under the per-circle precision control when set to Paused.
  ///
  /// In en, this message translates to:
  /// **'Paused — your location isn\'t shared with this circle.'**
  String get circlesDashPrecisionPaused;

  /// Label above the home screen's precision control, naming the selected circle it applies to.
  ///
  /// In en, this message translates to:
  /// **'What {circle} sees'**
  String homePrecisionFor(String circle);

  /// Hint under the home precision control explaining it only affects the selected circle.
  ///
  /// In en, this message translates to:
  /// **'Each circle has its own setting. Change the others in My circles.'**
  String get homePrecisionPerCircleHint;

  /// Snackbar when writing a circle's precision mode failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t change that. Please try again.'**
  String get precisionChangeFailed;

  /// Heading of the no-circle onboarding fork, shown to a signed-in user who is in no circle yet.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get forkTitle;

  /// Subtitle under the onboarding fork heading.
  ///
  /// In en, this message translates to:
  /// **'You\'re not in a circle yet. Choose how you\'d like to begin.'**
  String get forkSubtitle;

  /// Title of the create-a-circle option on the onboarding fork.
  ///
  /// In en, this message translates to:
  /// **'Create a circle'**
  String get forkCreateTitle;

  /// Body of the create-a-circle option on the onboarding fork.
  ///
  /// In en, this message translates to:
  /// **'Start a private circle on our server and invite your family with a link.'**
  String get forkCreateBody;

  /// Button on the create-a-circle option that opens the name dialog.
  ///
  /// In en, this message translates to:
  /// **'Create a circle'**
  String get forkCreateCta;

  /// Title of the join-a-circle option on the onboarding fork.
  ///
  /// In en, this message translates to:
  /// **'Join a circle'**
  String get forkJoinTitle;

  /// Body of the join-a-circle option on the onboarding fork.
  ///
  /// In en, this message translates to:
  /// **'Got an invite link? Paste it to join an existing circle.'**
  String get forkJoinBody;

  /// Button on the join-a-circle option that opens the paste-link dialog.
  ///
  /// In en, this message translates to:
  /// **'Join with a link'**
  String get forkJoinCta;

  /// Title of the self-hosting option on the onboarding fork (coming soon).
  ///
  /// In en, this message translates to:
  /// **'Run your own server'**
  String get forkSelfHostTitle;

  /// Body of the self-hosting option, explaining honestly what it means and its trade-off.
  ///
  /// In en, this message translates to:
  /// **'Run Aul on your own computer so your data never leaves your machine. It needs the computer kept on.'**
  String get forkSelfHostBody;

  /// Badge and disabled-button label marking the self-hosting option as not yet available.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get forkComingSoon;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
