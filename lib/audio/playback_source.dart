/// What the current queue was started from, so pages can tell whether they
/// are the one playing and Now Playing can say "Playing from …".
enum SourceKind { album, playlist, artist, radio, mix }

class PlaybackSource {
  const PlaybackSource(this.kind, this.id, this.title);

  final SourceKind kind;
  final String id;
  final String title;

  String get label => switch (kind) {
    SourceKind.album => 'PLAYING FROM ALBUM',
    SourceKind.playlist => 'PLAYING FROM PLAYLIST',
    SourceKind.artist => 'PLAYING FROM ARTIST',
    SourceKind.radio => 'PLAYING RADIO',
    SourceKind.mix => 'PLAYING FROM YOUR MIX',
  };

  /// Route segment under a shell tab, e.g. `album/<id>`. Radio has no page.
  String? get path => kind == SourceKind.radio ? null : '${kind.name}/$id';

  Map<String, Object> toJson() => {'kind': kind.name, 'id': id, 'title': title};

  static PlaybackSource? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = SourceKind.values.where((k) => k.name == j['kind']).firstOrNull;
    if (kind == null || j['id'] == null) return null;
    return PlaybackSource(kind, '${j['id']}', '${j['title'] ?? ''}');
  }

  @override
  bool operator ==(Object other) => other is PlaybackSource && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}
