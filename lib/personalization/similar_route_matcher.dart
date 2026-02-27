import 'models/personalization_models.dart';

class SimilarRouteMatch {
  const SimilarRouteMatch({required this.entry, required this.score});

  final RouteHistoryEntry entry;
  final double score;
}

class SimilarRouteMatcher {
  const SimilarRouteMatcher();

  SimilarRouteMatch? findBest({
    required String queryNorm,
    required List<RouteHistoryEntry> candidates,
    double threshold = 0.56,
  }) {
    if (queryNorm.trim().isEmpty || candidates.isEmpty) return null;

    SimilarRouteMatch? best;
    for (final entry in candidates) {
      final score = _score(queryNorm, entry.queryNorm);
      if (score < threshold) continue;
      if (best == null || score > best.score) {
        best = SimilarRouteMatch(entry: entry, score: score);
      }
    }
    return best;
  }

  double _score(String a, String b) {
    final aNorm = a.trim();
    final bNorm = b.trim();
    if (aNorm.isEmpty || bNorm.isEmpty) return 0;
    if (aNorm == bNorm) return 1;

    final aTokens = _tokens(aNorm);
    final bTokens = _tokens(bNorm);
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;

    final intersection = aTokens.intersection(bTokens).length.toDouble();
    final union = aTokens.union(bTokens).length.toDouble();
    final jaccard = union == 0 ? 0 : intersection / union;

    var score = jaccard;
    if (aNorm.contains(bNorm) || bNorm.contains(aNorm)) {
      score += 0.18;
    }
    final prefixBonus = _prefixBonus(aTokens, bTokens);
    score += prefixBonus;
    return score.clamp(0, 1).toDouble();
  }

  Set<String> _tokens(String text) {
    return text
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.length > 1)
        .where((token) => !_stopWords.contains(token))
        .toSet();
  }

  double _prefixBonus(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    var prefixHits = 0;
    for (final tokenA in a) {
      for (final tokenB in b) {
        if (tokenA == tokenB) continue;
        if (tokenA.length < 4 || tokenB.length < 4) continue;
        if (tokenA.startsWith(tokenB) || tokenB.startsWith(tokenA)) {
          prefixHits++;
          if (prefixHits >= 2) return 0.12;
          break;
        }
      }
    }
    return prefixHits == 1 ? 0.06 : 0;
  }
}

const Set<String> _stopWords = {
  'до',
  'по',
  'к',
  'в',
  'на',
  'и',
  'или',
  'ул',
  'улица',
  'дом',
  'проспект',
  'пр',
  'кв',
  'район',
  'бей',
  'дейін',
  'қарай',
  'көшесі',
  'көше',
  'үй',
};
