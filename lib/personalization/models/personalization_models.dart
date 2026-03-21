enum ResponseLength { short, medium, detailed }

extension ResponseLengthX on ResponseLength {
  static ResponseLength fromStorage(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'short':
        return ResponseLength.short;
      case 'detailed':
        return ResponseLength.detailed;
      case 'medium':
      default:
        return ResponseLength.medium;
    }
  }

  String get storageValue => name;
}

enum ToneStyle { neutral, warm, direct }

extension ToneStyleX on ToneStyle {
  static ToneStyle fromStorage(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'neutral':
        return ToneStyle.neutral;
      case 'direct':
        return ToneStyle.direct;
      case 'warm':
      default:
        return ToneStyle.warm;
    }
  }

  String get storageValue => name;
}

class UserProfile {
  const UserProfile({
    this.id = 1,
    this.displayName = '',
    this.responseLength = ResponseLength.medium,
    this.toneStyle = ToneStyle.warm,
    this.warningIntensity = 2,
    this.onboardingCompleted = false,
    this.onboardingStep = 0,
    this.onboardingDeferredUntilEpochMs,
    this.confirmAddressBeforeRoute = true,
    this.preferSaferRoute = true,
    required this.createdAtEpochMs,
    required this.updatedAtEpochMs,
  });

  final int id;
  final String displayName;
  final ResponseLength responseLength;
  final ToneStyle toneStyle;
  final int warningIntensity;
  final bool onboardingCompleted;
  final int onboardingStep;
  final int? onboardingDeferredUntilEpochMs;
  final bool confirmAddressBeforeRoute;
  final bool preferSaferRoute;
  final int createdAtEpochMs;
  final int updatedAtEpochMs;

  factory UserProfile.initial({required int nowEpochMs}) {
    return UserProfile(
      createdAtEpochMs: nowEpochMs,
      updatedAtEpochMs: nowEpochMs,
    );
  }

  UserProfile copyWith({
    int? id,
    String? displayName,
    ResponseLength? responseLength,
    ToneStyle? toneStyle,
    int? warningIntensity,
    bool? onboardingCompleted,
    int? onboardingStep,
    Object? onboardingDeferredUntilEpochMs = _noChange,
    bool? confirmAddressBeforeRoute,
    bool? preferSaferRoute,
    int? createdAtEpochMs,
    int? updatedAtEpochMs,
  }) {
    return UserProfile(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      responseLength: responseLength ?? this.responseLength,
      toneStyle: toneStyle ?? this.toneStyle,
      warningIntensity: warningIntensity ?? this.warningIntensity,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      onboardingStep: onboardingStep ?? this.onboardingStep,
      onboardingDeferredUntilEpochMs:
          onboardingDeferredUntilEpochMs == _noChange
          ? this.onboardingDeferredUntilEpochMs
          : onboardingDeferredUntilEpochMs as int?,
      confirmAddressBeforeRoute:
          confirmAddressBeforeRoute ?? this.confirmAddressBeforeRoute,
      preferSaferRoute: preferSaferRoute ?? this.preferSaferRoute,
      createdAtEpochMs: createdAtEpochMs ?? this.createdAtEpochMs,
      updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
    );
  }

  static const Object _noChange = Object();
}

class UserFear {
  const UserFear({
    this.id,
    this.fearKey,
    this.customText = '',
    this.severity = 2,
    this.source = 'voice',
    this.active = true,
    required this.updatedAtEpochMs,
  });

  final int? id;
  final String? fearKey;
  final String customText;
  final int severity;
  final String source;
  final bool active;
  final int updatedAtEpochMs;

  String get displayText {
    if (customText.trim().isNotEmpty) return customText.trim();
    return (fearKey ?? '').trim();
  }
}

class PlaceLabel {
  const PlaceLabel({
    this.id,
    required this.labelName,
    required this.labelNameNorm,
    required this.addressText,
    required this.lat,
    required this.lon,
    required this.createdAtEpochMs,
    required this.updatedAtEpochMs,
  });

  final int? id;
  final String labelName;
  final String labelNameNorm;
  final String addressText;
  final double lat;
  final double lon;
  final int createdAtEpochMs;
  final int updatedAtEpochMs;
}

class RouteHistoryEntry {
  const RouteHistoryEntry({
    this.id,
    required this.queryText,
    required this.queryNorm,
    required this.resolvedAddress,
    required this.destLat,
    required this.destLon,
    required this.source,
    required this.startedAtEpochMs,
    this.completed = true,
  });

  final int? id;
  final String queryText;
  final String queryNorm;
  final String resolvedAddress;
  final double destLat;
  final double destLon;
  final String source;
  final int startedAtEpochMs;
  final bool completed;
}

class PersonalizationSnapshot {
  const PersonalizationSnapshot({
    required this.profile,
    required this.fears,
    required this.placeLabels,
    required this.answers,
  });

  final UserProfile profile;
  final List<UserFear> fears;
  final List<PlaceLabel> placeLabels;
  final Map<int, String> answers;

  static PersonalizationSnapshot initial({required int nowEpochMs}) {
    return PersonalizationSnapshot(
      profile: UserProfile.initial(nowEpochMs: nowEpochMs),
      fears: const [],
      placeLabels: const [],
      answers: const {},
    );
  }

  bool get onboardingCompleted => profile.onboardingCompleted;

  List<String> get activeFearTexts {
    return fears
        .where((fear) => fear.active)
        .map((fear) => fear.displayText)
        .where((text) => text.isNotEmpty)
        .toList(growable: false);
  }
}
