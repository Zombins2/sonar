// Library > Songs has a Shuffle button like Downloads, shuffling the whole
// library rather than the 60 songs loaded so far.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/audio/player_controls.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/data/library_sort.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/ui/widgets/media_tiles.dart';

import 'harness.dart';
import 'fake_library.dart';

/// Records what the screens ask the player to play.
class _Recorder implements PlayerControls {
  final played = <({List<Song> songs, bool shuffle})>[];

  @override
  Future<void> playSongs(
    List<Song> songs, {
    int index = 0,
    bool shuffle = false,
    Object? source,
    Duration position = Duration.zero,
  }) async => played.add((songs: songs, shuffle: shuffle));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('Songs: Shuffle plays random songs from the whole library, shuffled', (tester) async {
    final recorder = _Recorder();
    final h = await pumpSonar(tester, extra: (_) => [controlsProvider.overrideWithValue(recorder)]);
    h.router.go('/library');
    await h.settle(4);
    await tester.tap(find.text('Songs'));
    await h.settle(6);

    final shuffle = find.widgetWithText(FilledButton, 'Shuffle');
    expect(shuffle, findsOneWidget);
    expect(find.text('All songs'), findsOneWidget);
    await tester.tap(shuffle);
    await h.settle(4);

    final asked = h.adapter.requests.where((u) => u.pathSegments.last == 'getRandomSongs').toList();
    expect(asked, hasLength(1));
    expect(asked.single.queryParameters['size'], '500', reason: 'the whole library, not the loaded page');
    expect(asked.single.queryParameters.containsKey('genre'), isFalse);
    expect(recorder.played, hasLength(1));
    expect(recorder.played.single.songs, hasLength(6), reason: 'what the server sent');
    expect(recorder.played.single.shuffle, isTrue);
  });

  testWidgets('Songs and Artists: the sort reorders them, offering only what each tab can do', (tester) async {
    final h = await pumpSonar(tester);
    h.router.go('/library');
    await h.settle(4);
    await tester.tap(find.text('Songs'));
    await h.settle(6);

    List<String> shown(String Function(Song s) of) => [
      for (final t in tester.widgetList<SongTile>(find.byType(SongTile))) of(t.song),
    ];
    Future<void> pick(String label) async {
      await tester.tap(find.byTooltip('Sort'));
      await h.settle(2);
      await tester.tap(find.text(label).last);
      await h.settle(4);
    }

    final all = [
      for (var i = 0; i < FakeLibrary.albums.length; i++)
        for (var t = 0; t < 5; t++) Song.fromJson(FakeLibrary.song(i, t)),
    ];
    await pick('A–Z');
    final titles = shown((s) => s.title);
    expect(titles, isNotEmpty);
    expect(titles, [for (final s in sortSongs(all, LibrarySort.alpha)) s.title].take(titles.length));
    await pick('Artist');
    final artists = shown((s) => s.artist);
    expect(artists, [for (final s in sortSongs(all, LibrarySort.artist)) s.artist].take(artists.length));
    expect(artists, isNot(titles), reason: 'a different order');

    await tester.tap(find.text('Artists'));
    await h.settle(4);
    await tester.tap(find.byTooltip('Sort'));
    await h.settle(2);
    expect(find.text('Recently added'), findsWidgets);
    expect(find.widgetWithText(CheckedPopupMenuItem<LibrarySort>, 'Artist'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await h.settle(2);
    await tester.tap(find.text('Downloads'));
    await h.settle(4);
    expect(find.byTooltip('Sort'), findsNothing);
  });
}
