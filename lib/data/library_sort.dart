import 'subsonic/models.dart';

/// How the Library tabs are ordered.
enum LibrarySort {
  recent('Recently added', AlbumListType.newest),
  alpha('A–Z', AlbumListType.alphabeticalByName),
  artist('Artist', AlbumListType.alphabeticalByArtist);

  const LibrarySort(this.label, this.albumType);
  final String label;

  /// The server's own order for albums.
  final AlbumListType albumType;
}

/// The Library's tabs, in order, and the sorts each offers. Artists and
/// playlists have no artist order of their own; downloads have none.
enum LibraryTab {
  playlists([LibrarySort.recent, LibrarySort.alpha]),
  albums(LibrarySort.values),
  artists([LibrarySort.recent, LibrarySort.alpha]),
  songs(LibrarySort.values),
  downloads([]);

  const LibraryTab(this.sorts);
  final List<LibrarySort> sorts;

  /// [chosen] where this tab has it, else A–Z.
  LibrarySort sortOf(LibrarySort chosen) => sorts.contains(chosen) ? chosen : LibrarySort.alpha;
}

int _byName(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

/// [songs] in [sort] order. The Subsonic API hands songs out in no order of
/// its own, so the whole list is sorted here:
/// - recently added: newest first, then each album's tracks in order;
/// - A–Z: by title;
/// - artist: by artist, then album, then track.
List<Song> sortSongs(List<Song> songs, LibrarySort sort) {
  int track(Song a, Song b) {
    final disc = (a.discNumber ?? 0).compareTo(b.discNumber ?? 0);
    return disc != 0 ? disc : (a.track ?? 0).compareTo(b.track ?? 0);
  }

  final out = [...songs];
  switch (sort) {
    case LibrarySort.recent:
      out.sort((a, b) {
        final c = (b.created ?? DateTime(0)).compareTo(a.created ?? DateTime(0));
        if (c != 0) return c;
        final album = _byName(a.album, b.album);
        return album != 0 ? album : track(a, b);
      });
    case LibrarySort.alpha:
      out.sort((a, b) {
        final c = _byName(a.title, b.title);
        return c != 0 ? c : _byName(a.artist, b.artist);
      });
    case LibrarySort.artist:
      out.sort((a, b) {
        final artist = _byName(a.artist, b.artist);
        if (artist != 0) return artist;
        final album = _byName(a.album, b.album);
        return album != 0 ? album : track(a, b);
      });
  }
  return out;
}

/// [artists] in [sort] order. Recently added: by their newest album, as
/// [newest] (albums newest first) lists them; artists with no album there
/// come last, A–Z. A–Z keeps the server's order (which files "The Wailers"
/// under W).
List<Artist> sortArtists(List<Artist> artists, LibrarySort sort, List<Album> newest) {
  if (sort != LibrarySort.recent) return artists;
  final rank = <String, int>{};
  for (final (i, a) in newest.indexed) {
    if (a.artistId != null) rank.putIfAbsent(a.artistId!, () => i);
  }
  final order = {for (final (i, a) in artists.indexed) a.id: i};
  return [...artists]..sort((a, b) {
    final ra = rank[a.id], rb = rank[b.id];
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null || rb != null) return ra != null ? -1 : 1;
    return order[a.id]!.compareTo(order[b.id]!);
  });
}
