import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/audio/playback_source.dart';
import 'package:sonar/data/db/database.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/downloads/download_manager.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/ui/widgets/media_tiles.dart';
import 'package:sonar/ui/widgets/now_playing_bars.dart';

const songs = [
  Song(id: 's1', title: 'First', track: 1, albumId: 'al1'),
  Song(id: 's2', title: 'Second', track: 2, albumId: 'al1'),
];

Widget harness({
  String? currentSong,
  String? currentAlbum,
  PlaybackSource? source,
  bool reachable = true,
  required Widget child,
}) => ProviderScope(
  overrides: [
    clientProvider.overrideWithValue(null),
    // Never initialised or queried: an empty download list.
    downloadManagerProvider.overrideWith((_) => DownloadManager(AppDatabase(NativeDatabase.memory()))),
    reachableProvider.overrideWith((_) => reachable),
    currentSongIdProvider.overrideWithValue(currentSong),
    currentAlbumIdProvider.overrideWithValue(currentAlbum),
    playingProvider.overrideWith((_) => Stream.value(true)),
    playbackSourceProvider.overrideWith((_) => Stream.value(source)),
  ],
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  testWidgets('only the current track swaps its number for playing bars', (tester) async {
    await tester.pumpWidget(
      harness(
        currentSong: 's2',
        child: Column(
          children: [
            for (var i = 0; i < songs.length; i++)
              SongTile(song: songs[i], queue: songs, index: i, showArt: false, trackNumber: songs[i].track),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(NowPlayingBars), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsNothing);
    final bars = tester.widget<NowPlayingBars>(find.byType(NowPlayingBars));
    expect(bars.animate, isTrue);
  });

  testWidgets('no bars when nothing from the list is playing', (tester) async {
    await tester.pumpWidget(
      harness(
        currentSong: 'other',
        child: SongTile(song: songs.first, queue: songs, index: 0, showArt: false, trackNumber: 1),
      ),
    );
    await tester.pump();
    expect(find.byType(NowPlayingBars), findsNothing);
  });

  testWidgets('album badge follows the current track\'s album', (tester) async {
    await tester.pumpWidget(
      harness(
        currentAlbum: 'al1',
        child: const Row(children: [PlayingBadge.album('al1'), PlayingBadge.album('al2')]),
      ),
    );
    await tester.pump();
    expect(find.byType(NowPlayingBars), findsOneWidget);
  });

  testWidgets('playlist badge needs the queue to have started from that playlist', (tester) async {
    await tester.pumpWidget(
      harness(
        source: const PlaybackSource(SourceKind.playlist, 'pl1', 'Mix'),
        child: const Row(children: [PlayingBadge.playlist('pl1'), PlayingBadge.playlist('pl2')]),
      ),
    );
    await tester.pump();
    expect(find.byType(NowPlayingBars), findsOneWidget);
  });

  testWidgets('offline, songs that are not downloaded fade back', (tester) async {
    double opacity() => tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;
    Widget tile(bool reachable) => harness(
      reachable: reachable,
      child: SongTile(song: songs.first, queue: songs, index: 0, showArt: false, trackNumber: 1),
    );

    await tester.pumpWidget(tile(true));
    expect(opacity(), 1);

    // A ProviderScope keeps its first overrides, so start a fresh tree.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(tile(false));
    expect(opacity(), lessThan(1));
  });

  test('PlaybackSource round-trips and compares by kind + id', () {
    const s = PlaybackSource(SourceKind.album, 'a1', 'Blue');
    expect(PlaybackSource.fromJson(s.toJson()), s);
    expect(PlaybackSource.fromJson(s.toJson())!.title, 'Blue');
    expect(s, const PlaybackSource(SourceKind.album, 'a1', 'renamed'));
    expect(s == const PlaybackSource(SourceKind.playlist, 'a1', 'Blue'), isFalse);
    expect(PlaybackSource.fromJson({'kind': 'bogus', 'id': 'x'}), isNull);
  });
}
