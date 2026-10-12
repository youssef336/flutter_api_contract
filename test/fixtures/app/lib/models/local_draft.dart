class LocalDraft {
  LocalDraft(this.text);

  factory LocalDraft.fromJson(Map<String, dynamic> json) =>
      LocalDraft(json['text'] as String);

  final String text;
}

class CacheEntry {
  CacheEntry(this.key);

  factory CacheEntry.fromJson(Map<String, dynamic> json) =>
      CacheEntry(json['key'] as String);

  final String key;
}
