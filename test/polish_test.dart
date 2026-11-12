import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/core/nav.dart';
import 'package:sonar/core/theme.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/ui/screens/genre_screen.dart';
import 'package:sonar/ui/screens/now_playing_screen.dart';
import 'package:sonar/ui/widgets/common.dart';
import 'package:sonar/ui/widgets/media_tiles.dart';

import 'now_playing_indicator_test.dart' show harness;
import 'support/fake_server.dart';

void main() {
  group('qualityLabel', () {
    test('lossless files say so', () {
      expect(qualityLabel(suffix: 'flac', bitRate: 920), 'FLAC · Lossless');
    });

    test('lossy files show their bitrate', () {
      expect(qualityLabel(suffix: 'mp3', bitRate: 320), 'MP3 · 320 kbps');
      expect(qualityLabel(suffix: 'opus'), 'OPUS');
    });

    test('a quality cap shows what is actually streamed, not the file', () {
      expect(qualityLabel(suffix: 'flac', bitRate: 920, streamKbps: 192), 'MP3 · 192 kbps');
    });

    test('nothing to say without a format', () {
      expect(qualityLabel(), isNull);
    });
  });

  group('FadingTitleBar.tracker', () {
    Future<double Function(double, {int depth, Axis axis})> setUp(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      return (double pixels, {int depth = 0, Axis axis = Axis.vertical}) {
        final progress = ValueNotifier(0.0);
        FadingTitleBar.tracker(progress, 300, span: 40)(
          ScrollUpdateNotification(
            metrics: FixedScrollMetrics(
              minScrollExtent: 0,
              maxScrollExtent: 2000,
              pixels: pixels,
              viewportDimension: 800,
              axisDirection: axis == Axis.vertical ? AxisDirection.down : AxisDirection.right,
              devicePixelRatio: 1,
            ),
            context: context,
            depth: depth,
          ),
        );
        return progress.value;
      };
    }

    testWidgets('see-through until the header title reaches the bar, solid after', (tester) async {
      final progressAt = await setUp(tester);
      expect(progressAt(0), 0);
      expect(progressAt(300), 0);
      expect(progressAt(320), closeTo(0.5, 1e-9));
      expect(progressAt(340), 1);
      expect(progressAt(900), 1);
    });

    testWidgets('ignores nested and sideways scrolling (carousels, inner lists)', (tester) async {
      final progressAt = await setUp(tester);
      expect(progressAt(900, depth: 1), 0);
      expect(progressAt(900, axis: Axis.horizontal), 0);
    });
  });

  testWidgets('list ends leave room for the player bar inside the tabs, the gesture bar outside', (tester) async {
    double? inside, outside;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(bottom: 16)),
        child: Column(
          children: [
            BottomChrome(
              height: ValueNotifier(150),
              child: Builder(
                builder: (c) {
                  inside = bottomInset(c);
                  return const SizedBox();
                },
              ),
            ),
            Builder(
              builder: (c) {
                outside = bottomInset(c);
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    );
    expect(inside, 150 + 24);
    expect(outside, 16 + 24);
  });

  test('neighbouring genre tiles never share a colour', () {
    for (var i = 0; i < 30; i++) {
      expect(genreColor('x', i), isNot(genreColor('x', i + 1)));
    }
    expect(genreColor('Jazz'), genreColor('jazz'), reason: 'unindexed colour is stable per name');
  });

  test('DetailPreview accepts a bare hero tag or a preview', () {
    expect(DetailPreview.of('tag').heroTag, 'tag');
    expect(DetailPreview.of('tag').title, isNull);
    final p = DetailPreview.of(
      DetailPreview.album(
        const Album(id: 'a', name: 'Low Tide', coverArt: 'c1'),
        heroTag: 'h',
      ),
    );
    expect((p.heroTag, p.title, p.coverArt), ('h', 'Low Tide', 'c1'));
  });

  group('genre endpoints', () {
    test('getGenres drops blank names; getAlbumsByGenre asks for byGenre', () async {
      final server = fakeServer({
        'getGenres': ok({
          'genres': {
            'genre': [
              {'value': 'Jazz', 'albumCount': 3, 'songCount': 30},
              {'value': '', 'albumCount': 1},
            ],
          },
        }),
      });
      final genres = await server.client.getGenres();
      expect(genres.map((g) => (g.name, g.albumCount)), [('Jazz', 3)]);

      await server.client.getAlbumsByGenre('Hip-Hop & Soul');
      final q = server.adapter.requests.last.queryParameters;
      expect((q['type'], q['genre']), ('byGenre', 'Hip-Hop & Soul'));
    });
  });

  group('album track rows', () {
    const album = [
      Song(id: 's1', title: 'Own Song', track: 1, artist: 'Juniper Vale'),
      Song(id: 's2', title: 'Feature', track: 2, artist: 'Juniper Vale feat. Sol'),
    ];

    testWidgets('only name the artist on tracks by someone else', (tester) async {
      await tester.pumpWidget(
        harness(
          child: Column(
            children: [
              for (var i = 0; i < album.length; i++)
                SongTile(song: album[i], queue: album, index: i, showArt: false, contextArtist: 'Juniper Vale'),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Juniper Vale'), findsNothing);
      expect(find.text('Juniper Vale feat. Sol'), findsOneWidget);
    });
  });

  testWidgets('snackbars use the app font, not the system one', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSonarTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added'))),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    final paragraph = tester.renderObject<RenderParagraph>(find.text('Added'));
    expect(paragraph.text.style?.fontFamily, SonarFonts.family);
  });
}
