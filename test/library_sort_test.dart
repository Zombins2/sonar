import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/library_sort.dart';
import 'package:sonar/data/subsonic/models.dart';

Song _s(String title, String artist, String album, {int track = 1, int disc = 1, DateTime? added}) => Song(
  id: '$title$track',
  title: title,
  artist: artist,
  album: album,
  track: track,
  discNumber: disc,
  created: added,
);

List<String> _titles(List<Song> songs) => [for (final s in songs) s.title];

void main() {
  final day = DateTime(2026, 11, 16);
  final songs = [
    _s('Zion', 'Bob Marley', 'Exodus', track: 2, added: day.subtract(const Duration(days: 3))),
    _s('ayo', 'Chronixx', 'Chronology', track: 1, added: day),
    _s('Jamming', 'Bob Marley', 'Exodus', track: 1, added: day.subtract(const Duration(days: 3))),
    _s('Back', 'Bob Marley', 'Exodus', track: 1, disc: 2, added: day.subtract(const Duration(days: 3))),
    _s('Legalize It', 'Peter Tosh', 'Legalize It', track: 1, added: day.subtract(const Duration(days: 1))),
  ];

  test('songs, recently added: newest first, then each album in track order', () {
    expect(_titles(sortSongs(songs, LibrarySort.recent)), ['ayo', 'Legalize It', 'Jamming', 'Zion', 'Back']);
  });

  test('songs, A–Z: by title, ignoring case', () {
    expect(_titles(sortSongs(songs, LibrarySort.alpha)), ['ayo', 'Back', 'Jamming', 'Legalize It', 'Zion']);
  });

  test('songs, by artist: then album, then disc and track', () {
    expect(_titles(sortSongs(songs, LibrarySort.artist)), ['Jamming', 'Zion', 'Back', 'ayo', 'Legalize It']);
  });

  test('artists, recently added: by their newest album; any without one last, as the server listed them', () {
    const artists = [
      Artist(id: 'a', name: 'Bob Marley'),
      Artist(id: 'b', name: 'Chronixx'),
      Artist(id: 'c', name: 'Dusqk'),
      Artist(id: 'd', name: 'Peter Tosh'),
    ];
    const newest = [
      Album(id: '1', name: 'Chronology', artistId: 'b'),
      Album(id: '2', name: 'Legalize It', artistId: 'd'),
      Album(id: '3', name: 'Dela', artistId: 'b'),
      Album(id: '4', name: 'Exodus', artistId: 'a'),
    ];
    expect(
      [for (final a in sortArtists(artists, LibrarySort.recent, newest)) a.name],
      ['Chronixx', 'Peter Tosh', 'Bob Marley', 'Dusqk'],
    );
    expect(sortArtists(artists, LibrarySort.alpha, newest), artists, reason: 'the server\'s A–Z');
  });

  test('each tab offers what it can do; a sort it lacks reads as A–Z', () {
    expect(LibraryTab.artists.sorts, isNot(contains(LibrarySort.artist)));
    expect(LibraryTab.artists.sortOf(LibrarySort.artist), LibrarySort.alpha);
    expect(LibraryTab.songs.sortOf(LibrarySort.artist), LibrarySort.artist);
    expect(LibraryTab.downloads.sorts, isEmpty);
  });
}
