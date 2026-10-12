/// `json_serializable`'s `FieldRename`, applied the same way the generator
/// does it.
enum FieldRename {
  none,
  kebab,
  snake,
  pascal,
  screamingSnake;

  /// Parses `snake`, `FieldRename.snake`, `screaming_snake`, ...
  static FieldRename? tryParse(String? raw) {
    if (raw == null) return null;
    final name = raw.split('.').last.replaceAll('_', '').toLowerCase();
    for (final v in values) {
      if (v.name.toLowerCase() == name) return v;
    }
    return null;
  }

  String apply(String field) => switch (this) {
    FieldRename.none => field,
    FieldRename.kebab => _fixCase(field, '-'),
    FieldRename.snake => _fixCase(field, '_'),
    FieldRename.pascal =>
      field.isEmpty ? field : field[0].toUpperCase() + field.substring(1),
    FieldRename.screamingSnake => _fixCase(field, '_').toUpperCase(),
  };
}

final _upper = RegExp('[A-Z]');

String _fixCase(String input, String separator) =>
    input.replaceAllMapped(_upper, (m) {
      final lower = m.group(0)!.toLowerCase();
      return m.start > 0 ? '$separator$lower' : lower;
    });
