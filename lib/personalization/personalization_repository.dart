import 'package:sqflite/sqflite.dart';

import 'data/personalization_database.dart';
import 'models/personalization_models.dart';
import 'similar_route_matcher.dart';

class PersonalizationRepository {
  PersonalizationRepository({
    required PersonalizationDatabase database,
    SimilarRouteMatcher? similarRouteMatcher,
  }) : _database = database,
       _similarRouteMatcher =
           similarRouteMatcher ?? const SimilarRouteMatcher();

  final PersonalizationDatabase _database;
  final SimilarRouteMatcher _similarRouteMatcher;

  Future<UserProfile?> getProfile() async {
    final db = await _database.database;
    final rows = await db.query('user_profile', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    return _profileFromRow(rows.first);
  }

  Future<void> upsertProfile(UserProfile profile) async {
    final db = await _database.database;
    await db.insert(
      'user_profile',
      _profileToRow(profile),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveQuestionAnswer(
    int questionId,
    String questionKey,
    String rawAnswer, {
    String? normalizedValue,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('questionnaire_answers', {
      'question_id': questionId,
      'question_key': questionKey,
      'raw_answer': rawAnswer.trim(),
      'normalized_value': normalizedValue?.trim(),
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearQuestionnaireAnswers() async {
    final db = await _database.database;
    await db.delete('questionnaire_answers');
  }

  Future<Map<int, String>> getAnswersMap() async {
    final db = await _database.database;
    final rows = await db.query(
      'questionnaire_answers',
      columns: ['question_id', 'raw_answer'],
    );
    final result = <int, String>{};
    for (final row in rows) {
      result[(row['question_id'] as int?) ?? 0] =
          (row['raw_answer'] as String?) ?? '';
    }
    return result;
  }

  Future<void> upsertFear(UserFear fear) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final fearKey = fear.fearKey?.trim();
    final custom = fear.customText.trim();

    final existing = await db.query(
      'user_fears',
      where: '(fear_key = ? OR custom_text = ?) AND active = 1',
      whereArgs: [fearKey ?? '', custom],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      await db.update(
        'user_fears',
        {
          'severity': fear.severity.clamp(1, 3),
          'source': fear.source.trim().isEmpty ? 'voice' : fear.source.trim(),
          'active': fear.active ? 1 : 0,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      return;
    }

    await db.insert('user_fears', {
      'fear_key': fearKey,
      'custom_text': custom,
      'severity': fear.severity.clamp(1, 3),
      'source': fear.source.trim().isEmpty ? 'voice' : fear.source.trim(),
      'active': fear.active ? 1 : 0,
      'updated_at': now,
    });
  }

  Future<List<UserFear>> getFears() async {
    final db = await _database.database;
    final rows = await db.query('user_fears', orderBy: 'updated_at DESC');
    return rows.map(_fearFromRow).toList(growable: false);
  }

  Future<void> clearOnboardingFears() async {
    final db = await _database.database;
    await db.delete(
      'user_fears',
      where: 'source = ?',
      whereArgs: ['onboarding'],
    );
  }

  Future<void> upsertPlaceLabel(PlaceLabel label) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final norm = normalizeText(
      label.labelNameNorm.isEmpty ? label.labelName : label.labelNameNorm,
    );
    if (norm.isEmpty) return;

    final existing = await db.query(
      'place_labels',
      where: 'label_name_norm = ?',
      whereArgs: [norm],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert('place_labels', {
        'label_name': label.labelName.trim(),
        'label_name_norm': norm,
        'address_text': label.addressText.trim(),
        'lat': label.lat,
        'lon': label.lon,
        'created_at': now,
        'updated_at': now,
      });
      return;
    }

    final row = existing.first;
    await db.update(
      'place_labels',
      {
        'label_name': label.labelName.trim(),
        'address_text': label.addressText.trim(),
        'lat': label.lat,
        'lon': label.lon,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [row['id']],
    );
  }

  Future<PlaceLabel?> findPlaceLabelByName(String name) async {
    final lookupNorms = _buildPlaceLabelLookupNorms(name);
    if (lookupNorms.isEmpty) return null;
    final db = await _database.database;
    final direct = await _findPlaceLabelByNorms(db, lookupNorms);
    if (direct != null) return direct;

    final rows = await db.query('place_labels', orderBy: 'updated_at DESC');
    for (final row in rows) {
      final labelNorm = (row['label_name_norm'] as String?)?.trim() ?? '';
      if (labelNorm.isEmpty) continue;
      if (lookupNorms.any(
        (candidate) =>
            labelNorm == candidate ||
            labelNorm.contains(candidate) ||
            candidate.contains(labelNorm),
      )) {
        return _labelFromRow(row);
      }
    }
    return null;
  }

  Future<List<PlaceLabel>> getPlaceLabels() async {
    final db = await _database.database;
    final rows = await db.query('place_labels', orderBy: 'updated_at DESC');
    return rows.map(_labelFromRow).toList(growable: false);
  }

  Future<List<RouteHistoryEntry>> getRecentRoutes({int limit = 50}) async {
    final db = await _database.database;
    final rows = await db.query(
      'route_history',
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(_routeFromRow).toList(growable: false);
  }

  Future<void> recordRouteUsage(RouteHistoryEntry entry) async {
    final db = await _database.database;
    await db.insert('route_history', {
      'query_text': entry.queryText.trim(),
      'query_norm': normalizeText(
        entry.queryNorm.isEmpty ? entry.queryText : entry.queryNorm,
      ),
      'resolved_address': entry.resolvedAddress.trim(),
      'dest_lat': entry.destLat,
      'dest_lon': entry.destLon,
      'source': entry.source.trim().isEmpty ? 'manual' : entry.source.trim(),
      'started_at': entry.startedAtEpochMs,
      'completed': entry.completed ? 1 : 0,
    });
  }

  Future<RouteHistoryEntry?> findBestSimilarRoute(String query) async {
    final queryNorm = normalizeText(query);
    if (queryNorm.isEmpty) return null;
    final candidates = await getRecentRoutes(limit: 120);
    final match = _similarRouteMatcher.findBest(
      queryNorm: queryNorm,
      candidates: candidates,
      threshold: 0.5,
    );
    return match?.entry;
  }

  Future<void> close() => _database.close();

  UserProfile _profileFromRow(Map<String, Object?> row) {
    return UserProfile(
      id: (row['id'] as int?) ?? 1,
      displayName: (row['display_name'] as String?) ?? '',
      responseLength: ResponseLengthX.fromStorage(
        row['response_length'] as String?,
      ),
      toneStyle: ToneStyleX.fromStorage(row['tone_style'] as String?),
      warningIntensity: ((row['warning_intensity'] as int?) ?? 2).clamp(1, 3),
      onboardingCompleted: ((row['onboarding_completed'] as int?) ?? 0) == 1,
      onboardingStep: ((row['onboarding_step'] as int?) ?? 0).clamp(0, 10),
      onboardingDeferredUntilEpochMs: row['onboarding_deferred_until'] as int?,
      createdAtEpochMs: (row['created_at'] as int?) ?? 0,
      updatedAtEpochMs: (row['updated_at'] as int?) ?? 0,
    );
  }

  Map<String, Object?> _profileToRow(UserProfile profile) {
    return {
      'id': 1,
      'display_name': profile.displayName.trim(),
      'response_length': profile.responseLength.storageValue,
      'tone_style': profile.toneStyle.storageValue,
      'warning_intensity': profile.warningIntensity.clamp(1, 3),
      'onboarding_completed': profile.onboardingCompleted ? 1 : 0,
      'onboarding_step': profile.onboardingStep.clamp(0, 10),
      'onboarding_deferred_until': profile.onboardingDeferredUntilEpochMs,
      'created_at': profile.createdAtEpochMs,
      'updated_at': profile.updatedAtEpochMs,
    };
  }

  UserFear _fearFromRow(Map<String, Object?> row) {
    return UserFear(
      id: row['id'] as int?,
      fearKey: row['fear_key'] as String?,
      customText: (row['custom_text'] as String?) ?? '',
      severity: ((row['severity'] as int?) ?? 2).clamp(1, 3),
      source: (row['source'] as String?) ?? 'voice',
      active: ((row['active'] as int?) ?? 1) == 1,
      updatedAtEpochMs: (row['updated_at'] as int?) ?? 0,
    );
  }

  PlaceLabel _labelFromRow(Map<String, Object?> row) {
    return PlaceLabel(
      id: row['id'] as int?,
      labelName: (row['label_name'] as String?) ?? '',
      labelNameNorm: (row['label_name_norm'] as String?) ?? '',
      addressText: (row['address_text'] as String?) ?? '',
      lat: ((row['lat'] as num?) ?? 0).toDouble(),
      lon: ((row['lon'] as num?) ?? 0).toDouble(),
      createdAtEpochMs: (row['created_at'] as int?) ?? 0,
      updatedAtEpochMs: (row['updated_at'] as int?) ?? 0,
    );
  }

  RouteHistoryEntry _routeFromRow(Map<String, Object?> row) {
    return RouteHistoryEntry(
      id: row['id'] as int?,
      queryText: (row['query_text'] as String?) ?? '',
      queryNorm: (row['query_norm'] as String?) ?? '',
      resolvedAddress: (row['resolved_address'] as String?) ?? '',
      destLat: ((row['dest_lat'] as num?) ?? 0).toDouble(),
      destLon: ((row['dest_lon'] as num?) ?? 0).toDouble(),
      source: (row['source'] as String?) ?? 'manual',
      startedAtEpochMs: (row['started_at'] as int?) ?? 0,
      completed: ((row['completed'] as int?) ?? 1) == 1,
    );
  }

  Future<PlaceLabel?> _findPlaceLabelByNorms(
    Database db,
    List<String> norms,
  ) async {
    if (norms.isEmpty) return null;
    final placeholders = List.filled(norms.length, '?').join(', ');
    final rows = await db.query(
      'place_labels',
      where: 'label_name_norm IN ($placeholders)',
      whereArgs: norms,
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _labelFromRow(rows.first);
  }

  List<String> _buildPlaceLabelLookupNorms(String rawInput) {
    final normalized = normalizeText(rawInput);
    if (normalized.isEmpty) return const [];

    final norms = <String>[];
    void addNorm(String value) {
      final clean = normalizeText(value);
      if (clean.length < 2) return;
      if (!norms.contains(clean)) {
        norms.add(clean);
      }
    }

    addNorm(normalized);

    final tokens = normalized.split(' ').where((t) => t.isNotEmpty).toList();
    var start = 0;
    while (start < tokens.length - 1 &&
        _labelLeadingWords.contains(tokens[start])) {
      start++;
      addNorm(tokens.sublist(start).join(' '));
    }

    // Reuse current list size to safely append new variants while iterating.
    for (var i = 0; i < norms.length; i++) {
      final phrase = norms[i];
      addNorm(_manualLabelAlias(phrase));
      final words = phrase.split(' ').where((w) => w.isNotEmpty).toList();
      if (words.isEmpty) continue;
      final tail = words.last;
      for (final variantTail in _labelWordVariants(tail)) {
        final updatedWords = [...words]..[words.length - 1] = variantTail;
        addNorm(updatedWords.join(' '));
      }
    }

    return norms;
  }

  String _manualLabelAlias(String value) {
    return _labelAliases[value] ?? value;
  }

  Set<String> _labelWordVariants(String word) {
    final variants = <String>{word};

    void addTailTrimmed(String ending) {
      if (word.length <= ending.length + 1) return;
      if (!word.endsWith(ending)) return;
      variants.add(word.substring(0, word.length - ending.length));
    }

    const ruEndings = <String>[
      'ой',
      'ом',
      'ем',
      'ам',
      'ям',
      'ах',
      'ях',
      'ою',
      'ею',
      'ую',
      'юю',
      'ов',
      'ев',
      'а',
      'я',
      'ы',
      'и',
      'е',
      'у',
      'ю',
      'о',
    ];
    for (final ending in ruEndings) {
      addTailTrimmed(ending);
    }

    const kzEndings = <String>[
      'ға',
      'ге',
      'қа',
      'ке',
      'га',
      'ге',
      'ка',
      'ке',
      'да',
      'де',
      'та',
      'те',
      'на',
      'не',
    ];
    for (final ending in kzEndings) {
      addTailTrimmed(ending);
    }

    if (word.endsWith('ы') || word.endsWith('и') || word.endsWith('у')) {
      final base = word.substring(0, word.length - 1);
      if (base.length >= 2) {
        variants.add('$baseа');
        variants.add('$baseя');
      }
    }

    return variants;
  }

  static const Set<String> _labelLeadingWords = {
    'до',
    'да',
    'к',
    'ко',
    'в',
    'во',
    'на',
    'по',
    'маршрут',
    'бағыт',
    'багыт',
  };

  static const Map<String, String> _labelAliases = {
    'дома': 'дом',
    'домой': 'дом',
    'доме': 'дом',
    'домом': 'дом',
    'работы': 'работа',
    'работе': 'работа',
    'работу': 'работа',
    'работой': 'работа',
    'үйге': 'үй',
    'үйде': 'үй',
    'уйге': 'уй',
    'уйде': 'уй',
    'жұмысқа': 'жұмыс',
    'жұмыста': 'жұмыс',
    'жумыска': 'жумыс',
    'жумыста': 'жумыс',
  };
}

String normalizeText(String text) {
  var value = text.toLowerCase().replaceAll('ё', 'е');
  value = value.replaceAll(RegExp(r'[\n\r]'), ' ');
  value = value.replaceAll(
    RegExp(r'[^a-zA-Zа-яА-ЯәіңғүұқөһӘІҢҒҮҰҚӨҺ0-9 ]'),
    ' ',
  );
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return value;
}
