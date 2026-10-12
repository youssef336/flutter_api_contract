/// Edit distance between [a] and [b].
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final del = previous[j] + 1;
      final ins = current[j - 1] + 1;
      final sub = previous[j - 1] + cost;
      current[j] = del < ins
          ? (del < sub ? del : sub)
          : (ins < sub ? ins : sub);
    }
    final tmp = previous;
    previous = current;
    current = tmp;
  }
  return previous[b.length];
}

/// `user_name`, `userName`, `UserName`, `user-name` all normalize the same.
String normalizeKey(String key) =>
    key.replaceAll(RegExp('[_\\-\\s]'), '').toLowerCase();

/// The candidate closest to [key], or `null` when nothing is close enough.
///
/// Case/separator-only differences (`userName` vs `user_name`) always win.
String? closest(String key, Iterable<String> candidates) {
  final normalized = normalizeKey(key);
  String? best;
  var bestScore = 1 << 30;
  for (final c in candidates) {
    final score = normalizeKey(c) == normalized
        ? 0
        : 1 + levenshtein(normalized, normalizeKey(c));
    if (score < bestScore) {
      bestScore = score;
      best = c;
    }
  }
  if (best == null) return null;
  final limit = normalized.length <= 4 ? 1 : (normalized.length / 3).ceil();
  return bestScore - 1 <= limit ? best : null;
}
