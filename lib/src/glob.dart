/// A tiny glob matcher for `exclude:` patterns: `**` crosses folders, `*`
/// and `?` stay inside one path segment.
class Glob {
  Glob(this.pattern) : _regex = RegExp('^${_toRegex(pattern)}\$');

  final String pattern;
  final RegExp _regex;

  bool matches(String path) => _regex.hasMatch(path.replaceAll(r'\', '/'));

  static String _toRegex(String glob) {
    final b = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          i++;
          if (i + 1 < glob.length && glob[i + 1] == '/') {
            i++;
            b.write('(?:.*/)?');
          } else {
            b.write('.*');
          }
        } else {
          b.write('[^/]*');
        }
      } else if (c == '?') {
        b.write('[^/]');
      } else {
        b.write(RegExp.escape(c));
      }
    }
    return b.toString();
  }
}
