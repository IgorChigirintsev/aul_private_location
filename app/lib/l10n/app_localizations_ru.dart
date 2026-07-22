// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get onboardingNotifTitle => 'Честное, заметное уведомление';

  @override
  String get onboardingNotifBody =>
      'Пока вы делитесь местоположением, Aul всегда показывает уведомление — скрытого режима нет. Приостановить можно в любой момент. Разрешите уведомления, чтобы всегда знать, когда передача включена.';

  @override
  String get onboardingNotifCta => 'Разрешить уведомления';

  @override
  String get onboardingLocationTitle => 'Геолокация во время работы приложения';

  @override
  String get onboardingLocationBody =>
      'Aul нужна ваша геолокация, чтобы передавать её — в зашифрованном виде — вашему кругу. Расшифровать её может только ваш круг; сервер видит лишь шифртекст.';

  @override
  String get onboardingLocationCta => 'Разрешить геолокацию';

  @override
  String get onboardingBackgroundTitle =>
      'Пусть передача продолжается в кармане';

  @override
  String get onboardingBackgroundBody =>
      'Чтобы семья видела вас, даже когда приложение закрыто, выберите «Разрешать всегда» на следующем экране. Вы остаётесь у руля и можете остановить передачу мгновенно.';

  @override
  String get onboardingBackgroundCta => 'Разрешить в фоне';

  @override
  String get onboardingBatteryTitle => 'Не дайте системе усыпить передачу';

  @override
  String get onboardingBatteryBody =>
      'Некоторые телефоны агрессивно останавливают фоновые приложения. Если исключить Aul из оптимизации батареи, геолокация будет оставаться актуальной (расход заряда всё равно совсем небольшой).';

  @override
  String get onboardingBatteryCta => 'Завершить настройку';

  @override
  String get onboardingSkip => 'Пропустить пока';

  @override
  String get appTagline =>
      'Приватная семейная геолокация со сквозным шифрованием. Мы никогда не видим, где вы, — проверьте код.';

  @override
  String get loginCreateAccount => 'Создать аккаунт';

  @override
  String get loginSignIn => 'Войти';

  @override
  String get loginServerLabel => 'Сервер';

  @override
  String get loginServerHint => 'https://ваш-aul-сервер';

  @override
  String get loginEmailLabel => 'Эл. почта';

  @override
  String get loginPasswordLabel => 'Пароль';

  @override
  String get loginKeyReassurance =>
      'Ключ вашей геолокации никогда не покидает устройство. Сервер хранит только шифртекст.';

  @override
  String get genericError => 'Что-то пошло не так';

  @override
  String get whoCanSeeMe => 'Кто меня видит';

  @override
  String get aboutTitle => 'О приложении и обновления';

  @override
  String get debugTitle => 'Батарея и отладка';

  @override
  String get signOut => 'Выйти';

  @override
  String get homeSharingFooter =>
      'Во время передачи всегда показывается уведомление. Остановить можно мгновенно.';

  @override
  String get sosSentSuccess =>
      'SOS отправлен — идёт передача в реальном времени вашим кругам';

  @override
  String get sosSentFailure =>
      'Не удалось отправить SOS (на этом устройстве нет ключа круга)';

  @override
  String get whoCanSeeMeNobody => 'Вы пока ни с кем не делитесь.';

  @override
  String whoCanSeeMeCircles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count кругам',
      many: '$count кругам',
      few: '$count кругам',
      one: '$count кругу',
    );
    return 'Ваше зашифрованное местоположение доступно $_temp0. Расшифровать его могут только участники круга — сервер не может.';
  }

  @override
  String get joinCircleTitle => 'Присоединиться к кругу';

  @override
  String get joinCircleHint => 'Вставьте пригласительную ссылку';

  @override
  String get cancel => 'Отмена';

  @override
  String get join => 'Присоединиться';

  @override
  String get joinedCircle => 'Вы присоединились к кругу';

  @override
  String get couldNotJoin => 'Не удалось присоединиться';

  @override
  String get sharingOn => 'Геолокация передаётся';

  @override
  String get sharingOff => 'Передача выключена';

  @override
  String get precisionPrecise => 'Точно';

  @override
  String get precisionCity => 'Город';

  @override
  String get precisionPaused => 'Пауза';

  @override
  String get stopSharing => 'Остановить передачу';

  @override
  String get startSharing => 'Начать передачу';

  @override
  String get joinCircleFirst =>
      'Сначала присоединитесь к кругу, чтобы начать передачу.';

  @override
  String get sosActiveBanner =>
      'SOS активен — идёт передача в реальном времени вашим кругам';

  @override
  String get errorRateLimited =>
      'Слишком много попыток. Подождите немного и попробуйте снова.';

  @override
  String get errorAccountLocked =>
      'Слишком много попыток — аккаунт временно заблокирован. Попробуйте позже.';

  @override
  String get errorPayloadTooLarge => 'Слишком большой размер для отправки.';

  @override
  String get errorInternal =>
      'Что-то пошло не так на нашей стороне. Попробуйте ещё раз.';

  @override
  String get errorTimeout => 'Время ожидания истекло. Попробуйте ещё раз.';

  @override
  String get errorForbidden => 'Недостаточно прав для этого действия.';

  @override
  String sosInOtherCircle(String names) {
    return 'SOS в круге $names — открыть';
  }

  @override
  String get noCirclesYet => 'Пока нет кругов';

  @override
  String circlesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count круга',
      many: '$count кругов',
      few: '$count круга',
      one: '$count круг',
    );
    return '$_temp0';
  }

  @override
  String get joinByLink => 'Присоединиться по ссылке';

  @override
  String get sosSendTitle => 'Отправить SOS?';

  @override
  String get sosSendBody =>
      'Это оповестит всех в ваших кругах и включит передачу в реальном времени, пока вы её не завершите.';

  @override
  String get sosSend => 'Отправить SOS';

  @override
  String get sosHold => 'Удерживайте для SOS';

  @override
  String get sosSemantic =>
      'SOS. Удерживайте, чтобы отправить экстренный сигнал.';

  @override
  String get aboutTagline =>
      'Приватная семейная геолокация со сквозным шифрованием.';

  @override
  String get aboutVersionLabel => 'Версия';

  @override
  String aboutVersionValue(String versionName, int versionCode) {
    return '$versionName (сборка $versionCode)';
  }

  @override
  String get aboutVersionUnknown => 'неизвестно';

  @override
  String get updatesManagedByStore =>
      'Обновления для этой платформы устанавливаются через ваш магазин приложений.';

  @override
  String get updateUpToDate => 'У вас установлена последняя версия.';

  @override
  String get updateCheckError => 'Не удалось проверить обновления.';

  @override
  String get updateCheckPrompt => 'Проверьте, доступна ли новая сборка.';

  @override
  String get updateCheckButton => 'Проверить обновления';

  @override
  String get locationExtras => 'Дополнительные возможности';

  @override
  String get locationExtrasSubtitle =>
      'Необязательно, приватно и по умолчанию выключено. Всё это вычисляется на вашем устройстве — сервер не узнаёт ничего нового.';

  @override
  String get serverDisabledFeatures => 'Ваш сервер отключил эти функции.';

  @override
  String get arrivalAlertsTitle => 'Оповещения о прибытии';

  @override
  String get arrivalAlertsSubtitle =>
      'Уведомлять, когда я прихожу в сохранённое место или ухожу из него.';

  @override
  String get trackingRemindersTitle => 'Напоминания о передаче';

  @override
  String get trackingRemindersSubtitle =>
      'Напоминать, если передача остановилась или разряжается батарея.';

  @override
  String get themeLabel => 'Тема';

  @override
  String get themeSystem => 'Системная';

  @override
  String get themeLight => 'Светлая';

  @override
  String get themeDark => 'Тёмная';

  @override
  String get language => 'Язык';

  @override
  String get languageSystem => 'Системный';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageRussian => 'Русский';

  @override
  String get debugSharing => 'Передача';

  @override
  String get debugOn => 'Вкл';

  @override
  String get debugOff => 'Выкл';

  @override
  String get debugPrecision => 'Точность';

  @override
  String get debugCircles => 'Круги';

  @override
  String get debugQueuedPings => 'Пинги в очереди (не отправлены)';

  @override
  String get debugServer => 'Сервер';

  @override
  String get debugCadenceInfo =>
      'Адаптивная частота бережёт батарею: покой → 10 мин, ходьба → 60 с, поездка → 15 с, live/SOS → 5 с. Пинги группируются и повторяются с задержкой. Цель: ≤ 3 % заряда в день.';

  @override
  String get updateProblem => 'Проблема с обновлением';

  @override
  String get updateAvailable => 'Доступно обновление';

  @override
  String get updateGenericError => 'Что-то пошло не так.';

  @override
  String updateReadyToInstall(String versionName) {
    return 'Aul $versionName готов к установке.';
  }

  @override
  String get updateDownloading => 'Загрузка и проверка…';

  @override
  String get updateInstalling => 'Запуск установщика…';

  @override
  String get later => 'Позже';

  @override
  String get tryAgain => 'Повторить';

  @override
  String get updateNow => 'Обновить сейчас';

  @override
  String get updateCheckFailedRetry =>
      'Не удалось проверить обновления. Попробуйте ещё раз.';

  @override
  String get updateNeedInstallPermission =>
      'Разрешите «установку неизвестных приложений», чтобы обновить Aul.';

  @override
  String get updateIntegrityFailed =>
      'Обновление прервано: проверка целостности не пройдена.';

  @override
  String get updateDownloadFailed =>
      'Не удалось загрузить. Попробуйте ещё раз.';

  @override
  String get pushAlertsTitle => 'Уведомления, когда Aul закрыт';

  @override
  String get pushAlertsSubtitle =>
      'Разрешить уведомлениям вашего круга приходить на это устройство в фоне. Они расшифровываются на вашем телефоне — сервер только передаёт их и не может их прочитать.';

  @override
  String get notifChannelName => 'Напоминания Aul';

  @override
  String get notifChannelDescription =>
      'Оповещения о прибытии, напоминания о передаче и итоги недели.';

  @override
  String get notifArrivedTitle => 'Прибытие';

  @override
  String get notifLeftTitle => 'Уход';

  @override
  String notifArrivedBody(String place) {
    return 'Вы прибыли в «$place»';
  }

  @override
  String notifLeftBody(String place) {
    return 'Вы покинули «$place»';
  }

  @override
  String get notifCircleUpdateTitle => 'Новости круга';

  @override
  String notifMemberArrivedBody(String name, String place) {
    return '$name прибыл(а) в «$place»';
  }

  @override
  String notifMemberLeftBody(String name, String place) {
    return '$name покинул(а) «$place»';
  }

  @override
  String get notifSharingOffTitle => 'Передача выключена';

  @override
  String get notifSharingOffBody =>
      'Передача геолокации остановлена. Откройте Aul, чтобы возобновить.';

  @override
  String get notifBatteryLowTitle => 'Низкий заряд';

  @override
  String get notifBatteryLowBody =>
      'Из-за низкого заряда передача геолокации может работать хуже.';

  @override
  String sharingNotification(String label, String precision) {
    return 'Передача · $label · $precision';
  }

  @override
  String sosNotification(String label) {
    return 'SOS активен · передача в реальном времени · $label';
  }

  @override
  String get inviteInvalid => 'Недействительная пригласительная ссылка';

  @override
  String get inviteMissingKey => 'В пригласительной ссылке нет ключа круга';

  @override
  String get inviteMalformed => 'Ключ приглашения повреждён';

  @override
  String get inviteTitle => 'Пригласить в ваш круг';

  @override
  String get inviteSubtitle =>
      'Отправьте ссылку, по которой можно присоединиться';

  @override
  String get inviteCreating => 'Создаём приглашение…';

  @override
  String get inviteError => 'Не удалось создать приглашение';

  @override
  String get inviteNote =>
      'В этой ссылке — ключ вашего круга, в части после «#», которую сервер никогда не получает. Присоединиться к кругу может любой, у кого есть ссылка целиком, — делитесь ей только с близкими.';

  @override
  String get close => 'Закрыть';

  @override
  String get circleFallback => 'Ваш круг';

  @override
  String get circlesYours => 'Ваши круги';

  @override
  String get circleOwnerBadge => 'владелец';

  @override
  String get circleRoleMember => 'участник';

  @override
  String get switchCircle => 'Сменить круг';

  @override
  String get renameCircle => 'Переименовать круг';

  @override
  String get renameCircleHint => 'Новое название круга';

  @override
  String get rename => 'Переименовать';

  @override
  String get leaveCircle => 'Выйти из круга';

  @override
  String get leaveCircleTitle => 'Выйти из круга?';

  @override
  String get leaveCircleBody =>
      'Выйти из этого круга? Вы перестанете делиться геолокацией с ним и видеть его участников.';

  @override
  String get leave => 'Выйти';

  @override
  String get soleOwnerTitle => 'Удалить этот круг?';

  @override
  String get soleOwnerBody =>
      'Вы единственный владелец, поэтому просто выйти нельзя. Удалить этот круг для всех?';

  @override
  String get deleteCircle => 'Удалить круг';

  @override
  String get deleteCircleTitle => 'Удалить круг?';

  @override
  String deleteCircleBody(String name) {
    return 'Удалить «$name» для всех? Круг и все его данные будут безвозвратно удалены. Это действие необратимо.';
  }

  @override
  String get delete => 'Удалить';

  @override
  String get createCircle => 'Новый круг';

  @override
  String get createCircleHint => 'Название круга';

  @override
  String get create => 'Создать';

  @override
  String get circleRenamed => 'Круг переименован';

  @override
  String get circleLeft => 'Вы вышли из круга';

  @override
  String get circleDeleted => 'Круг удалён';

  @override
  String get circleCreated => 'Круг создан';

  @override
  String get circleActionFailed => 'Что-то пошло не так. Попробуйте ещё раз.';

  @override
  String get membersTitle => 'Участники';

  @override
  String get membersEmpty =>
      'Здесь пока никого нет. Пригласите близких по ссылке.';

  @override
  String get membersError =>
      'Не удалось загрузить участников. Потяните, чтобы повторить.';

  @override
  String get profileYou => '(вы)';

  @override
  String get verifyDevicesTitle => 'Проверить устройства';

  @override
  String get verifyDevicesIntro =>
      'Сравните эти коды вслух с каждым человеком. Если они совпадают на обоих телефонах, ключи шифрования никто не подменил. Сервер этих кодов не видит.';

  @override
  String get verifyDevicesEmpty =>
      'Пока нет других устройств для проверки. Они появятся здесь, когда в круг войдёт кто-то ещё.';

  @override
  String get verifyDevicesError =>
      'Не удалось загрузить устройства. Потяните, чтобы повторить.';

  @override
  String get rotateKey => 'Сменить ключ круга';

  @override
  String get rotateKeyTitle => 'Сменить ключ круга?';

  @override
  String get rotateKeyBody =>
      'Будет создан новый ключ шифрования для круга. Новые геопозиции, места и оповещения будут использовать новый ключ, и он в зашифрованном виде отправится на устройство каждого участника. Прежние данные останутся доступными. Сделайте это, если считаете, что старый ключ мог быть скомпрометирован.';

  @override
  String get rotateKeyConfirm => 'Сменить ключ';

  @override
  String get rotateKeySuccess => 'Ключ круга изменён';

  @override
  String get rotateKeyFailure => 'Не удалось сменить ключ. Попробуйте ещё раз.';

  @override
  String get editProfile => 'Изменить профиль';

  @override
  String get profileTitle => 'Ваш профиль в этом круге';

  @override
  String get profileNickname => 'Имя';

  @override
  String get profileNicknameHint => 'Как вас видят в этом круге';

  @override
  String get profilePhoto => 'Фото';

  @override
  String get profileChoosePhoto => 'Выбрать фото';

  @override
  String get profileChangePhoto => 'Изменить фото';

  @override
  String get profileRemovePhoto => 'Удалить фото';

  @override
  String get save => 'Сохранить';

  @override
  String get profileSaved => 'Профиль сохранён';

  @override
  String get profileTooLarge =>
      'Это изображение слишком большое. Попробуйте меньший фрагмент.';

  @override
  String get profileImageError =>
      'Не удалось прочитать изображение. Попробуйте другое.';

  @override
  String get profileSaveError =>
      'Не удалось сохранить профиль. Попробуйте ещё раз.';

  @override
  String get cropTitle => 'Обрезать фото';

  @override
  String get done => 'Готово';

  @override
  String get mapTitle => 'Карта';

  @override
  String get mapRecenter => 'Показать всех';

  @override
  String get mapNorthUp => 'Север вверх';

  @override
  String get mapRecenterOnMe => 'Показать меня';

  @override
  String get mapEmpty =>
      'Пока некого показать. Когда участники круга поделятся геопозицией, они появятся на карте.';

  @override
  String get mapTagPc => 'ПК';

  @override
  String get mapTagPhone => 'Телефон';

  @override
  String get placesTitle => 'Места';

  @override
  String get geofenceFeedTitle => 'В местах';

  @override
  String geofenceAtPlacesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count человека в местах',
      many: '$count человек в местах',
      few: '$count человека в местах',
      one: '$count человек в месте',
      zero: 'Никого нет в местах',
    );
    return '$_temp0';
  }

  @override
  String get geofenceNobody => 'Сейчас никто не находится в местах.';

  @override
  String geofencePresenceRow(String name, String place) {
    return '$name — в месте «$place»';
  }

  @override
  String get geofenceRecent => 'Недавно';

  @override
  String geofenceEventEnter(String name, String place) {
    return '$name прибыл в «$place»';
  }

  @override
  String geofenceEventExit(String name, String place) {
    return '$name ушёл из «$place»';
  }

  @override
  String get geofenceOnTheWay => 'В пути';

  @override
  String geofenceEtaRow(String name, String place) {
    return '$name → $place';
  }

  @override
  String get geofenceEtaLessMin => '<1 мин';

  @override
  String geofenceEtaMin(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count мин',
      one: '1 мин',
    );
    return '$_temp0';
  }

  @override
  String geofenceEtaHourMin(int h, int rem) {
    return '$h ч $rem мин';
  }

  @override
  String geofenceEtaHour(int h) {
    return '$h ч';
  }

  @override
  String membersAccuracy(String value, String unit) {
    return '±$value $unit';
  }

  @override
  String get unitMeters => 'м';

  @override
  String get unitKilometers => 'км';

  @override
  String get placesAddAPlace => 'Добавить место';

  @override
  String get placesNameHint => 'Название места (например, Дом)';

  @override
  String get placesRadiusLabel => 'Радиус геозоны';

  @override
  String placesRadiusValue(int meters) {
    return '$meters м';
  }

  @override
  String get placesTapMap => 'Нажмите на карту, чтобы задать центр.';

  @override
  String get placesCentreSet => 'Центр задан. Настройте радиус и сохраните.';

  @override
  String get placesAddPlace => 'Добавить место';

  @override
  String get placesSaveChanges => 'Сохранить изменения';

  @override
  String get placesEmpty => 'Мест пока нет. Добавьте Дом, Работу, Школу…';

  @override
  String placesConfirmDelete(String name) {
    return 'Удалить место «$name»?';
  }

  @override
  String get placesSaveFailed =>
      'Не удалось сохранить место. Попробуйте ещё раз.';

  @override
  String get sosCenterTitle => 'SOS';

  @override
  String get sosCenterNoMessage => 'Экстренный сигнал';

  @override
  String get sosCenterEncrypted =>
      'Подан SOS — не удаётся расшифровать на этом устройстве';

  @override
  String get sosCenterResolve => 'Снять';

  @override
  String get membersRemove => 'Удалить из круга';

  @override
  String get membersRemoveTitle => 'Удалить участника?';

  @override
  String get membersRemoveAction => 'Удалить';

  @override
  String membersRemoveConfirm(String name) {
    return 'Удалить $name из этого круга? Он перестанет видеть участников и делиться с вами геолокацией.';
  }

  @override
  String get membersRemoveFailed =>
      'Не удалось удалить участника. Попробуйте ещё раз.';

  @override
  String get membersRotateAfterRemove =>
      'У него остался старый ключ круга — он сможет читать данные, отправленные и дальше. Сменить ключ круга?';

  @override
  String get shareTitle => 'Ссылка на трансляцию';

  @override
  String get shareHomeHint =>
      'Покажите, где вы, одному человеку — без аккаунта и ровно столько, сколько решите.';

  @override
  String get shareIntro =>
      'Создаёт ссылку, по которой один человек будет видеть, где вы сейчас, — аккаунт не нужен. Ссылка достаётся тому, кто откроет её первым, остальные её уже не откроют. Она перестанет работать по истечении срока или как только вы её отзовёте.';

  @override
  String get shareDuration => 'На сколько';

  @override
  String get shareCreate => 'Создать ссылку';

  @override
  String get shareCreating => 'Создаём…';

  @override
  String get shareError => 'Не удалось создать ссылку';

  @override
  String get shareLinkTitle => 'Ваша ссылка';

  @override
  String get shareNote =>
      'Ключ, которым расшифровывается ваше местоположение, — это часть после #, и сервер её никогда не получает. Любой, у кого есть ссылка целиком, будет видеть вас до конца трансляции.';

  @override
  String get shareActive => 'Активные ссылки';

  @override
  String get shareNone => 'Активных ссылок нет.';

  @override
  String get shareClaimed => 'Открыта — ссылка у зрителя';

  @override
  String get shareUnclaimed =>
      'Ещё не открыта — достанется тому, кто откроет первым';

  @override
  String get shareNoKeyHere =>
      'Создана на другом устройстве: показать ссылку здесь нельзя, но отозвать можно.';

  @override
  String get shareRevoke => 'Отозвать';

  @override
  String get shareRevokeConfirm =>
      'Отозвать эту ссылку? Тот, кто смотрит, сразу перестанет вас видеть.';

  @override
  String get shareBannerSharing => 'Вы транслируете своё местоположение';

  @override
  String get shareNotification =>
      'Вы транслируете своё местоположение по ссылке';

  @override
  String get copy => 'Копировать';

  @override
  String get copied => 'Скопировано';

  @override
  String get sosHoldHint => 'Удерживайте кнопку SOS, чтобы отправить сигнал.';

  @override
  String get sosNoKeyHint =>
      'На этом устройстве нет ключа круга — зашифровать SOS пока не для кого.';

  @override
  String shareMinutes(int minutes) {
    return '$minutes мин';
  }

  @override
  String shareEndsIn(String countdown) {
    return 'Закончится через $countdown';
  }

  @override
  String shareBannerSharingMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ссылки',
      many: '$count ссылок',
      few: '$count ссылки',
      one: '$count ссылка',
    );
    return 'Вы транслируете своё местоположение · $_temp0';
  }

  @override
  String get circlesDashTitle => 'Мои круги';

  @override
  String get circlesDashSubtitle =>
      'Все круги, в которых вы состоите, и что вы даёте каждому из них.';

  @override
  String get circlesDashEmpty => 'Вы пока не состоите ни в одном круге.';

  @override
  String circlesDashYouAs(String nick) {
    return 'Вы как $nick';
  }

  @override
  String get circlesDashYouNoNick => 'Вы (имя здесь не задано)';

  @override
  String get circlesDashNotificationsTitle => 'Уведомления';

  @override
  String get circlesDashNotificationsOn =>
      'Участники этого круга могут присылать вам уведомления.';

  @override
  String get circlesDashNotificationsOff =>
      'Заглушено — уведомления от участников этого круга до вас не доходят.';

  @override
  String get circlesDashActionFailed => 'Не удалось сохранить изменение.';

  @override
  String membersMute(String name) {
    return 'Заглушить $name — его уведомления перестанут до вас доходить';
  }

  @override
  String membersUnmute(String name) {
    return 'Включить уведомления от $name снова';
  }

  @override
  String get membersMuteFailed => 'Не удалось изменить заглушение.';

  @override
  String placesAddedBy(String name) {
    return 'Добавил(а) $name';
  }

  @override
  String get agoJustNow => 'только что';

  @override
  String agoMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count минут назад',
      many: '$count минут назад',
      few: '$count минуты назад',
      one: '$count минуту назад',
    );
    return '$_temp0';
  }

  @override
  String agoHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count часов назад',
      many: '$count часов назад',
      few: '$count часа назад',
      one: '$count час назад',
    );
    return '$_temp0';
  }

  @override
  String batteryPercent(int pct) {
    return '$pct%';
  }

  @override
  String get batteryLabel => 'Заряд';

  @override
  String get membersNoPosition => 'Геолокации пока нет';

  @override
  String get staleBadge => 'Устарело';

  @override
  String get liveUpdatesPaused =>
      'Живое обновление на паузе — переподключение…';

  @override
  String connectionStale(String ago) {
    return 'Данные могут устареть — последнее соединение $ago';
  }

  @override
  String get circlesDashPrecisionTitle => 'Что видит этот круг';

  @override
  String get circlesDashPrecisionPrecise =>
      'Этот круг видит, где вы находитесь, точно.';

  @override
  String get circlesDashPrecisionCity =>
      'Этот круг видит только район города — не точное место.';

  @override
  String get circlesDashPrecisionPaused =>
      'Пауза — ваша геолокация не передаётся этому кругу.';

  @override
  String homePrecisionFor(String circle) {
    return 'Что видит круг «$circle»';
  }

  @override
  String get homePrecisionPerCircleHint =>
      'У каждого круга свои настройки. Остальные — в разделе «Мои круги».';

  @override
  String get precisionChangeFailed =>
      'Не удалось изменить. Попробуйте ещё раз.';

  @override
  String get forkTitle => 'С чего начать';

  @override
  String get forkSubtitle =>
      'Вы ещё не в круге. Выберите, с чего хотите начать.';

  @override
  String get forkCreateTitle => 'Создать круг';

  @override
  String get forkCreateBody =>
      'Создайте личный круг на нашем сервере и пригласите близких по ссылке.';

  @override
  String get forkCreateCta => 'Создать круг';

  @override
  String get forkJoinTitle => 'Присоединиться к кругу';

  @override
  String get forkJoinBody =>
      'Есть ссылка-приглашение? Вставьте её, чтобы войти в существующий круг.';

  @override
  String get forkJoinCta => 'Войти по ссылке';

  @override
  String get forkSelfHostTitle => 'Свой сервер';

  @override
  String get forkSelfHostBody =>
      'Запустите Aul на своём компьютере, чтобы данные не покидали вашу машину. Компьютер должен быть всегда включён.';

  @override
  String get forkComingSoon => 'Скоро';
}
