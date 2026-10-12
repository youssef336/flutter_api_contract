import 'dart:convert';
import 'dart:io';

import 'finding.dart';

/// Known drift that is accepted for now. It works like a ratchet: entries
/// can only be removed (`--update-baseline` never adds to an existing file).
class Baseline {
  Baseline(this.entries);

  /// Reads [path]; a missing file is an empty baseline.
  factory Baseline.load(String path) {
    final file = File(path);
    if (!file.existsSync()) return Baseline({});
    final Object? doc;
    try {
      doc = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw FormatException('Baseline $path is not valid JSON: ${e.message}');
    }
    final list = doc is Map ? doc['findings'] : doc;
    if (list is! List) {
      throw FormatException('Baseline $path has no "findings" list.');
    }
    return Baseline({for (final e in list) e.toString()});
  }

  final Set<String> entries;

  /// Splits [findings] into new ones and baselined ones, and reports the
  /// baseline entries that no longer occur (fixed drift).
  BaselineResult apply(List<Finding> findings) {
    final fresh = <Finding>[];
    final accepted = <Finding>[];
    final seen = <String>{};
    for (final f in findings) {
      if (entries.contains(f.fingerprint)) {
        accepted.add(f);
        seen.add(f.fingerprint);
      } else {
        fresh.add(f);
      }
    }
    return BaselineResult(
      fresh: fresh,
      accepted: accepted,
      stale: entries.difference(seen).toList()..sort(),
    );
  }

  /// The baseline to write for [findings].
  ///
  /// With [exists] false the baseline is created from every finding.
  /// Otherwise it only shrinks: fixed entries are dropped, new findings are
  /// never added.
  static Baseline next(
    Baseline current,
    List<Finding> findings, {
    required bool exists,
  }) {
    final now = findings.map((f) => f.fingerprint).toSet();
    return Baseline(exists ? current.entries.intersection(now) : now);
  }

  void save(String path) {
    final sorted = entries.toList()..sort();
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'version': 1, 'findings': sorted})}\n',
    );
  }
}

class BaselineResult {
  BaselineResult({
    required this.fresh,
    required this.accepted,
    required this.stale,
  });

  /// Findings not in the baseline: these are reported and can fail the run.
  final List<Finding> fresh;

  /// Findings hidden by the baseline.
  final List<Finding> accepted;

  /// Baseline entries that no longer occur: the baseline can shrink.
  final List<String> stale;
}
