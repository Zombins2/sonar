import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/soulbeet/get_music_search.dart';
import '../../data/soulbeet/soulbeet_downloads.dart';
import '../../data/soulbeet/soulbeet_models.dart';
import '../../data/soulbeet/source_pick.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import '../../state/soulbeet_providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import 'settings_screen.dart' show formatBytes;

/// Get music: find an album on MusicBrainz and have Soulbeet download it into
/// the library (docs/SOULBEET_PLAN.md).
class GetMusicScreen extends ConsumerStatefulWidget {
  const GetMusicScreen({super.key, this.initialQuery});
  final String? initialQuery;

  @override
  ConsumerState<GetMusicScreen> createState() => _GetMusicScreenState();
}

class _GetMusicScreenState extends ConsumerState<GetMusicScreen> {
  late final _controller = TextEditingController(text: widget.initialQuery ?? '');
  late String _query = widget.initialQuery?.trim() ?? '';

  /// "songs" and "albums" when showing everything, filler too.
  final _seeAll = <String>{};

  /// Searches once typing pauses, as a music app does.
  Timer? _typing;

  /// How long typing must pause before searching.
  static const typingPause = Duration(milliseconds: 500);

  @override
  void dispose() {
    _typing?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _search(String v) {
    _typing?.cancel();
    if (v.trim() == _query) return;
    setState(() {
      _query = v.trim();
      _seeAll.clear();
    });
  }

  void _typed(String v) {
    _typing?.cancel();
    if (v.trim().isEmpty) return _search('');
    if (v.trim().length < 2) return;
    _typing = Timer(typingPause, () => _search(v));
  }

  @override
  Widget build(BuildContext context) {
    final health = ref.watch(soulbeetHealthProvider);
    final available = ref.watch(soulbeetAvailableProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Get music'), actions: const [DownloadsButton(), SizedBox(width: 8)]),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: health.isLoading
              ? const LoadingState()
              : !available
              ? EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: 'Soulbeet isn\'t answering',
                  message:
                      'Get music downloads through Soulbeet beside Navidrome. Check it\'s running, then try again.',
                  action: FilledButton(
                    onPressed: () => ref.invalidate(soulbeetHealthProvider),
                    child: const Text('Try again'),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 8, SonarSpacing.gutter, 8),
                      child: TextField(
                        controller: _controller,
                        autofocus: widget.initialQuery == null,
                        onChanged: _typed,
                        onSubmitted: _search,
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w500),
                        cursorColor: Colors.black,
                        decoration: InputDecoration(
                          fillColor: Colors.white,
                          hintText: 'Artists, albums or songs',
                          hintStyle: const TextStyle(color: Color(0xFF555555)),
                          prefixIcon: const Icon(Icons.travel_explore_rounded, color: Colors.black87),
                          suffixIcon: IconButton(
                            tooltip: 'Search',
                            icon: const Icon(Icons.arrow_forward_rounded, color: Colors.black87),
                            onPressed: () => _search(_controller.text),
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: _results()),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _results() {
    if (_query.isEmpty) {
      return const EmptyState(
        icon: Icons.album_rounded,
        title: 'Find music to add',
        message:
            'Search for an artist, an album or a song on MusicBrainz. Sonar downloads the best FLAC copy it can '
            'find and files it in your library.',
      );
    }
    final results = ref.watch(soulbeetSearchProvider(_query));
    return results.when(
      skipLoadingOnReload: true,
      loading: () => const SkeletonRows(art: true),
      error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(soulbeetSearchProvider(_query))),
      data: (r) {
        if (r.isEmpty && !r.done) return const SkeletonRows(art: true);
        if (r.isEmpty) {
          return EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Nothing on MusicBrainz for "$_query"',
            message: 'Check the spelling, or try Artist - Album.',
          );
        }
        return _ResultsPage(results: r, seeAll: _seeAll, onSeeAll: (part) => setState(() => _seeAll.add(part)));
      },
    );
  }
}

/// Results as a music app lays them out: the top result, a few songs, a row
/// of albums, the filler behind "See all".
class _ResultsPage extends StatelessWidget {
  const _ResultsPage({required this.results, required this.seeAll, required this.onSeeAll});
  final GetMusicResults results;
  final Set<String> seeAll;
  final void Function(String part) onSeeAll;

  /// Songs shown before "See all".
  static const fewSongs = 4;

  /// Albums in the row before "See all".
  static const fewAlbums = 12;

  @override
  Widget build(BuildContext context) {
    final r = results;
    final top = r.topResult;
    final songs = [
      for (final s in r.songs)
        if (!identical(s, top)) s,
    ];
    final albums = [
      for (final a in r.allAlbums)
        if (!identical(a, top)) a,
    ];
    final allSongs = seeAll.contains('songs');
    final allAlbums = seeAll.contains('albums');
    final shownSongs = allSongs ? songs : songs.where((s) => !r.isFiller(s)).take(fewSongs).toList();
    final rowAlbums = albums.where((a) => !r.isFiller(a)).take(fewAlbums).toList();
    final secondary = Theme.of(context).textTheme.bodySmall?.copyWith(color: SonarColors.textSecondary);

    Widget seeAllButton(String part, int count) =>
        TextButton(onPressed: () => onSeeAll(part), child: Text('See all $count'));

    return ListView(
      padding: EdgeInsets.only(bottom: bottomInset(context)),
      children: [
        if (r.respelled != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 4, SonarSpacing.gutter, 0),
            child: Text('Also searched "${r.respelled}"', style: secondary),
          ),
        if (top != null) ...[
          const SectionHeader('Top result'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
            child: _TopResultCard(top: top, onArtist: () => onSeeAll('albums')),
          ),
        ],
        if (songs.isNotEmpty) ...[
          SectionHeader(
            'Songs',
            trailing: !allSongs && shownSongs.length < songs.length ? seeAllButton('songs', songs.length) : null,
          ),
          for (final s in shownSongs) GetSongTile(song: s),
          if (shownSongs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
              child: Text('Only little-known songs with this name.', style: secondary),
            ),
        ],
        if (albums.isNotEmpty) ...[
          SectionHeader(
            'Albums',
            trailing: !allAlbums && rowAlbums.length < albums.length ? seeAllButton('albums', albums.length) : null,
          ),
          if (allAlbums)
            for (final a in albums) GetAlbumTile(album: a)
          else if (rowAlbums.isNotEmpty)
            SizedBox(
              height: _AlbumCard.height,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
                itemCount: rowAlbums.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (_, i) => _AlbumCard(album: rowAlbums[i]),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
              child: Text('Only little-known albums with this name.', style: secondary),
            ),
        ],
        if (!r.done)
          const Padding(
            padding: EdgeInsets.all(SonarSpacing.gutter),
            child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
      ],
    );
  }
}

/// The likeliest thing searched for, big: an artist, an album or a song.
class _TopResultCard extends StatelessWidget {
  const _TopResultCard({required this.top, required this.onArtist});
  final Object top;
  final VoidCallback onArtist;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (title, kind, cover, open) = switch (top) {
      final TopArtist a => (a.name, 'Artist', a.cover, onArtist),
      final SbAlbum a => (a.title, 'Album · ${a.artist}', a, () => showAlbumSheet(context, a)),
      final SbTrack s => (
        s.title,
        'Song · ${s.artist}',
        s.onAlbum,
        () => showAlbumSheet(context, s.onAlbum!, song: s.title),
      ),
      _ => ('', '', null, () {}),
    };
    return Material(
      color: SonarColors.surfaceElevated,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              MbCover(mbid: cover?.mbid, groupId: cover?.groupId, size: 92, radius: top is TopArtist ? 46 : 8),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      kind,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: SonarColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An album in the row: its cover, title and year.
class _AlbumCard extends ConsumerWidget {
  const _AlbumCard({required this.album});
  final SbAlbum album;

  static const size = 140.0;
  static const height = size + 58;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final owned = ref.watch(libraryAlbumForProvider((title: album.title, artist: album.artist))).valueOrNull;
    final d = ref.watch(soulbeetDownloadsProvider)?.forFound(album);
    final kind = album.kinds.isNotEmpty ? album.kinds.first : null;
    return SizedBox(
      width: size,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showAlbumSheet(context, album),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                MbCover(mbid: album.mbid, groupId: album.groupId, size: size, radius: 8),
                if (d != null || owned != null)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: d != null
                        ? _Pill(phaseShort(d), icon: phaseIcon(d.phase), busy: d.active)
                        : const _Pill('Yours', icon: Icons.check_rounded),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
            Text(
              [?album.year, album.artist, ?kind].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: SonarColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A song found by name: tapping it opens the album it's on.
class GetSongTile extends StatelessWidget {
  const GetSongTile({super.key, required this.song});
  final SbTrack song;

  @override
  Widget build(BuildContext context) {
    final album = song.onAlbum!;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter, vertical: 2),
      leading: MbCover(mbid: album.mbid),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${song.artist} · on ${album.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showAlbumSheet(context, album, song: song.title),
    );
  }
}

/// A MusicBrainz album's cover (Cover Art Archive), or a placeholder: the
/// album's own ([groupId]) when known, else its pressing's ([mbid]).
class MbCover extends ConsumerWidget {
  const MbCover({super.key, required this.mbid, this.groupId, this.size = 56, this.radius = 6});
  final String? mbid;
  final String? groupId;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(coverImageOverrideProvider);
    final placeholder = Container(
      color: SonarColors.surfaceElevated,
      alignment: Alignment.center,
      child: Icon(Icons.album_rounded, color: SonarColors.textSecondary, size: size * 0.4),
    );
    final (kind, id) = groupId != null ? ('release-group', groupId) : ('release', mbid);
    Widget image;
    if (id == null) {
      image = placeholder;
    } else if (override != null) {
      image = Image(
        image: override(kind == 'release' ? 'mb:$id' : 'mbg:$id'),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else {
      image = CachedNetworkImage(
        imageUrl: 'https://coverartarchive.org/$kind/$id/front-${size > 120 ? 500 : 250}',
        cacheManager: coverCacheManager,
        fit: BoxFit.cover,
        fadeInDuration: SonarMotion.fast,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: image),
    );
  }
}

/// One search result: what it is, and whether it's already yours.
class GetAlbumTile extends ConsumerWidget {
  const GetAlbumTile({super.key, required this.album});
  final SbAlbum album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owned = ref.watch(libraryAlbumForProvider((title: album.title, artist: album.artist))).valueOrNull;
    final d = ref.watch(soulbeetDownloadsProvider)?.forFound(album);
    final subtitle = [album.artist, ?album.year].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter, vertical: 2),
      leading: MbCover(mbid: album.mbid, groupId: album.groupId),
      title: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: owned != null && d == null
          ? const _Pill('In your library', icon: Icons.check_rounded)
          : d != null
          ? _Pill(phaseShort(d), icon: phaseIcon(d.phase), busy: d.active)
          : const Icon(Icons.download_rounded),
      onTap: () => showAlbumSheet(context, album),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {required this.icon, this.busy = false});
  final String text;
  final IconData icon;
  final bool busy;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: SonarColors.surfaceElevated, borderRadius: BorderRadius.circular(99)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Icon(icon, size: 14, color: SonarColors.accentDefault),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

// ---- Words for where a download is ----------------------------------------------------

IconData phaseIcon(AlbumPhase p) => switch (p) {
  AlbumPhase.finding => Icons.travel_explore_rounded,
  AlbumPhase.downloading => Icons.download_rounded,
  AlbumPhase.importing => Icons.auto_fix_high_rounded,
  AlbumPhase.imported => Icons.check_circle_rounded,
  AlbumPhase.needsMatch => Icons.help_outline_rounded,
  AlbumPhase.failed => Icons.error_outline_rounded,
  AlbumPhase.cancelled => Icons.block_rounded,
};

String phaseShort(AlbumDownload d) => switch (d.phase) {
  AlbumPhase.finding => 'Finding',
  AlbumPhase.downloading => d.fraction == null || d.fraction == 0 ? 'Waiting' : '${(d.fraction! * 100).round()}%',
  AlbumPhase.importing => 'Filing',
  AlbumPhase.imported => 'Added',
  AlbumPhase.needsMatch => 'Pick a match',
  AlbumPhase.failed => 'Failed',
  AlbumPhase.cancelled => 'Cancelled',
};

String formatSpeed(double bytesPerSecond) => '${formatBytes(bytesPerSecond.round())}/s';

String qualityLabel(String? q) => q == null ? '' : q.toUpperCase();

/// One line on where an album download is up to.
String phaseLine(AlbumDownload d) {
  final from = d.source == null ? '' : ' from ${d.source}';
  final quality = d.quality == null ? '' : ' · ${qualityLabel(d.quality)}';
  return switch (d.phase) {
    AlbumPhase.finding => 'Looking for the best copy…',
    AlbumPhase.downloading when d.speed > 0 =>
      'Downloading$from$quality · ${d.filesDone}/${d.files.length} · ${formatSpeed(d.speed)}',
    AlbumPhase.downloading when d.files.isNotEmpty && d.filesDone > 0 =>
      'Downloading$from$quality · ${d.filesDone}/${d.files.length}',
    AlbumPhase.downloading => 'Waiting for ${d.source ?? 'the sharer'} to send it$quality',
    AlbumPhase.importing when d.retriedWithRelease => 'Filing it as the release you picked…',
    AlbumPhase.importing => 'Tagging and filing…',
    AlbumPhase.imported => d.libraryAlbumId == null ? 'Filed. Adding it to your library…' : 'In your library',
    AlbumPhase.needsMatch => 'beets wasn\'t sure which release this is',
    AlbumPhase.failed => d.error ?? 'It didn\'t download.',
    AlbumPhase.cancelled => 'Cancelled',
  };
}

// ---- The album sheet ---------------------------------------------------------------

/// Buttons side by side: the theme's are full width.
const _inline = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 48)));

/// The album's songs and a Download button; tapping songs picks some to
/// download alone. [song] (a title) is picked out when the album was found
/// through it.
Future<void> showAlbumSheet(BuildContext context, SbAlbum album, {String? song}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 620),
  builder: (_) => _AlbumSheet(found: album, song: song),
);

class _AlbumSheet extends ConsumerStatefulWidget {
  const _AlbumSheet({required this.found, this.song});
  final SbAlbum found;
  final String? song;

  @override
  ConsumerState<_AlbumSheet> createState() => _AlbumSheetState();
}

class _AlbumSheetState extends ConsumerState<_AlbumSheet> {
  /// Songs picked to download alone, by id.
  final _picked = <String>{};

  static String _plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final found = widget.found;
    // The pressing and its songs, usually fetched ahead by the search.
    final detail = ref.watch(albumSongsProvider(found));
    // A song's search result names the song's artists ("Steve Lacy, Erykah
    // Badu"); the album's own details name the album's.
    final album = detail.valueOrNull?.album ?? found;
    final downloads = ref.watch(soulbeetDownloadsProvider);
    final owned = ref.watch(libraryAlbumForProvider((title: album.title, artist: album.artist))).valueOrNull;
    final ownedTitles = owned == null
        ? const <String>{}
        : {for (final s in ref.watch(albumProvider(owned.id)).valueOrNull?.songs ?? const <Song>[]) _plain(s.title)};
    final d = downloads?.forFound(album);
    final tracks = detail.valueOrNull?.tracks ?? const <SbTrack>[];
    final length = tracks.fold(Duration.zero, (s, t) => s + (t.duration ?? Duration.zero));
    bool isOwned(SbTrack t) => ownedTitles.contains(_plain(t.title));
    final ownedTracks = tracks.where(isOwned).toList();
    final canPick = downloads != null && !album.needsPressing && tracks.isNotEmpty && !(d?.active ?? false);
    final picked = [
      for (final t in tracks)
        if (_picked.contains(t.id) && !isOwned(t)) t,
    ];

    Future<void> download({SbSource? chosen, List<SbTrack> songs = const []}) async {
      final nav = Navigator.of(context);
      final messenger = ScaffoldMessenger.maybeOf(context);
      nav.pop();
      final started = await downloads!.download(
        album,
        trackCount: tracks.isEmpty ? null : tracks.length,
        chosen: chosen,
        songs: songs,
      );
      if (started.phase == AlbumPhase.failed) {
        messenger?.showSnackBar(SnackBar(content: Text(started.error ?? 'Couldn\'t start the download.')));
      }
    }

    // Some songs: beets replaces an album it already has with what's filed
    // next, so the songs already in the library come along again.
    Future<void> downloadPicked() => download(
      songs: [
        for (final t in tracks)
          if (picked.contains(t) || isOwned(t)) t,
      ],
    );

    final List<Widget> actions;
    if (picked.isNotEmpty) {
      actions = [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              style: _inline,
              onPressed: canPick ? downloadPicked : null,
              icon: const Icon(Icons.download_rounded),
              label: Text(picked.length == 1 ? 'Download 1 song' : 'Download ${picked.length} songs'),
            ),
            OutlinedButton(onPressed: () => setState(_picked.clear), child: const Text('Clear')),
          ],
        ),
        if (ownedTracks.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'The ${ownedTracks.length == 1 ? 'song' : '${ownedTracks.length} songs'} you already have from this '
            'album download again too, so they stay filed together.',
            style: text.bodySmall?.copyWith(color: SonarColors.textSecondary),
          ),
        ],
      ];
    } else if (d != null) {
      actions = [
        Text(phaseLine(d), style: text.bodyMedium),
        const SizedBox(height: 12),
        Row(
          children: [
            if (d.libraryAlbumId != null)
              FilledButton.icon(
                style: _inline,
                onPressed: () {
                  Navigator.of(context).pop();
                  context.openAlbum(d.libraryAlbumId!);
                },
                icon: const Icon(Icons.album_rounded),
                label: const Text('Open album'),
              )
            else
              FilledButton.tonalIcon(
                style: _inline,
                onPressed: () {
                  Navigator.of(context).pop();
                  context.openMusicDownloads();
                },
                icon: const Icon(Icons.downloading_rounded),
                label: const Text('Downloads'),
              ),
          ],
        ),
      ];
    } else if (owned != null && ownedTracks.length >= tracks.length) {
      actions = [
        Text('Already in your library.', style: text.bodyMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              style: _inline,
              onPressed: () {
                Navigator.of(context).pop();
                context.openAlbum(owned.id);
              },
              icon: const Icon(Icons.album_rounded),
              label: const Text('Open album'),
            ),
            OutlinedButton(onPressed: album.needsPressing ? null : download, child: const Text('Download anyway')),
          ],
        ),
      ];
    } else {
      actions = [
        if (owned != null && ownedTracks.isNotEmpty) ...[
          Text('You have ${ownedTracks.length} of its ${tracks.length} songs.', style: text.bodyMedium),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              style: _inline,
              onPressed: downloads == null || album.needsPressing ? null : download,
              icon: const Icon(Icons.download_rounded),
              label: const Text('Download'),
            ),
            OutlinedButton.icon(
              onPressed: downloads == null || album.needsPressing
                  ? null
                  : () async {
                      final chosen = await showSourcePicker(context, album, tracks: tracks.length);
                      if (chosen != null && context.mounted) await download(chosen: chosen);
                    },
              icon: const Icon(Icons.tune_rounded),
              label: const Text('Choose source'),
            ),
          ],
        ),
      ];
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 20, SonarSpacing.gutter, 24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MbCover(mbid: album.mbid, groupId: found.groupId, size: 112, radius: 8),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(album.title, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(album.artist, style: text.bodyLarge),
                    const SizedBox(height: 4),
                    Text(
                      [
                        ?album.year,
                        if (tracks.isNotEmpty) '${tracks.length} songs',
                        if (length > Duration.zero) '${length.inMinutes} min',
                      ].join(' · '),
                      style: text.bodySmall?.copyWith(color: SonarColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ...actions,
          const SizedBox(height: 16),
          if (detail.isLoading) const SkeletonRows(count: 6),
          if (detail.hasError) Text(errorText(detail.error!), style: text.bodySmall),
          if (canPick && picked.isEmpty)
            Text(
              'Tap songs to download just those.',
              style: text.bodySmall?.copyWith(color: SonarColors.textSecondary),
            ),
          for (final (i, t) in tracks.indexed)
            _TrackRow(
              number: i + 1,
              track: t,
              picked: picked.contains(t),
              owned: isOwned(t),
              searchedFor: widget.song != null && _plain(t.title) == _plain(widget.song!),
              onTap: canPick && !isOwned(t)
                  ? () => setState(() => _picked.contains(t.id) ? _picked.remove(t.id) : _picked.add(t.id))
                  : null,
            ),
        ],
      ),
    );
  }
}

/// One of an album's songs: picked, already yours, or the one searched for.
class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.number,
    required this.track,
    required this.picked,
    required this.owned,
    required this.searchedFor,
    this.onTap,
  });
  final int number;
  final SbTrack track;
  final bool picked;
  final bool owned;
  final bool searchedFor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dim = text.bodySmall?.copyWith(color: SonarColors.textSecondary);
    final duration = track.duration;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: picked
                  ? const Icon(Icons.check_circle_rounded, size: 20, color: SonarColors.accentDefault)
                  : owned
                  ? Tooltip(
                      message: 'In your library',
                      child: Icon(Icons.library_music_rounded, size: 18, color: SonarColors.textSecondary),
                    )
                  : Text('$number', style: dim),
            ),
            Expanded(
              child: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: searchedFor || picked
                    ? const TextStyle(color: SonarColors.accentDefault, fontWeight: FontWeight.w700)
                    : null,
              ),
            ),
            if (duration != null)
              Text('${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}', style: dim),
          ],
        ),
      ),
    );
  }
}

// ---- Choose source ---------------------------------------------------------------

/// Lists the copies people share and returns the one picked.
Future<SbSource?> showSourcePicker(BuildContext context, SbAlbum album, {required int tracks}) =>
    showModalBottomSheet<SbSource>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (_) => _SourcePicker(album: album, tracks: tracks),
    );

class _SourcePicker extends ConsumerStatefulWidget {
  const _SourcePicker({required this.album, required this.tracks});
  final SbAlbum album;
  final int tracks;

  @override
  ConsumerState<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends ConsumerState<_SourcePicker> {
  StreamSubscription<SbSourceSearch>? _sub;
  SbSourceSearch? _latest;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final downloads = ref.read(soulbeetDownloadsProvider);
    _sub = downloads
        ?.findSources(widget.album)
        .listen((r) => setState(() => _latest = r), onError: (Object e) => setState(() => _error = e));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sources = [...?_latest?.sources]
      ..sort((a, b) {
        if (a.lossless != b.lossless) return a.lossless ? -1 : 1;
        return compareSources(a, b);
      });
    final best = pickSource(sources, tracks: widget.tracks);
    final searching = _latest == null || !_latest!.done;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (_, scroll) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 20, SonarSpacing.gutter, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('Choose a copy', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (searching) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
            child: Text(
              searching ? 'Asking who shares it…' : '${sources.length} copies found',
              style: text.bodySmall?.copyWith(color: SonarColors.textSecondary),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _error != null
                ? ErrorState(error: _error!, onRetry: () => Navigator.of(context).pop())
                : sources.isEmpty && !searching
                ? const EmptyState(icon: Icons.search_off_rounded, title: 'Nobody is sharing it right now')
                : ListView.builder(
                    controller: scroll,
                    itemCount: sources.length,
                    itemBuilder: (_, i) => _SourceTile(
                      source: sources[i],
                      best: identical(sources[i], best),
                      missing: widget.tracks > 0 && sources[i].itemCount < widget.tracks,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.source, required this.best, required this.missing});
  final SbSource source;
  final bool best;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final f = source.files.firstOrNull;
    final format = [
      qualityLabel(source.quality),
      if (f?.bitDepth != null && f?.sampleRate != null) '${f!.bitDepth}/${(f.sampleRate! / 1000).toStringAsFixed(1)}',
    ].join(' ');
    final wait = source.freeSlot
        ? 'Free now'
        : source.queueLength > 0
        ? '${source.queueLength} waiting'
        : 'Busy';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
      leading: Icon(
        source.lossless ? Icons.high_quality_rounded : Icons.music_note_rounded,
        color: source.lossless ? SonarColors.accentDefault : SonarColors.textSecondary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(format, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          if (best) ...[const SizedBox(width: 8), const _Pill('Best', icon: Icons.star_rounded)],
        ],
      ),
      subtitle: Text(
        [
          '${source.itemCount} files${missing ? ' (missing songs)' : ''}',
          formatBytes(source.totalSize),
          wait,
          if (source.uploadSpeed > 0) formatSpeed(source.uploadSpeed.toDouble()),
          source.user,
        ].join(' · '),
        maxLines: 2,
      ),
      onTap: () => Navigator.of(context).pop(source),
    );
  }
}

// ---- Downloads ---------------------------------------------------------------------

/// The Downloads button, with how many albums are on their way.
class DownloadsButton extends ConsumerWidget {
  const DownloadsButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(soulbeetDownloadsProvider)?.activeCount ?? 0;
    return IconButton(
      tooltip: 'Downloads',
      onPressed: context.openMusicDownloads,
      icon: Badge(
        isLabelVisible: active > 0,
        label: Text('$active'),
        backgroundColor: SonarColors.accentDefault,
        textColor: Colors.black,
        child: const Icon(Icons.downloading_rounded),
      ),
    );
  }
}

class MusicDownloadsScreen extends ConsumerStatefulWidget {
  const MusicDownloadsScreen({super.key});

  @override
  ConsumerState<MusicDownloadsScreen> createState() => _MusicDownloadsScreenState();
}

class _MusicDownloadsScreenState extends ConsumerState<MusicDownloadsScreen> {
  @override
  void initState() {
    super.initState();
    // Shows albums started elsewhere too (Soulbeet's page, the other device).
    unawaited(ref.read(soulbeetDownloadsProvider)?.watch());
  }

  @override
  Widget build(BuildContext context) {
    final downloads = ref.watch(soulbeetDownloadsProvider);
    final albums = downloads?.albums ?? const <AlbumDownload>[];
    final anyDone = albums.any((a) => !a.active && a.phase != AlbumPhase.needsMatch);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [if (anyDone) TextButton(onPressed: downloads!.clearFinished, child: const Text('Clear finished'))],
      ),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: albums.isEmpty
              ? const EmptyState(
                  icon: Icons.downloading_rounded,
                  title: 'Nothing downloading',
                  message: 'Albums you get show up here while they download and file into your library.',
                )
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(SonarSpacing.gutter, 8, SonarSpacing.gutter, bottomInset(context) + 16),
                  itemCount: albums.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => AlbumDownloadCard(d: albums[i]),
                ),
        ),
      ),
    );
  }
}

class AlbumDownloadCard extends ConsumerWidget {
  const AlbumDownloadCard({super.key, required this.d});
  final AlbumDownload d;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.read(soulbeetDownloadsProvider)!;
    final text = Theme.of(context).textTheme;
    final album = d.album;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: SonarColors.surface, borderRadius: BorderRadius.circular(SonarRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MbCover(mbid: album?.mbid, size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleMedium),
                    if (d.artist != null)
                      Text(d.artist!, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                    const SizedBox(height: 4),
                    Text(
                      phaseLine(d),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: d.phase == AlbumPhase.failed
                            ? Theme.of(context).colorScheme.error
                            : SonarColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(phaseIcon(d.phase), color: d.phase == AlbumPhase.imported ? SonarColors.accentDefault : null),
            ],
          ),
          if (d.phase == AlbumPhase.downloading ||
              d.phase == AlbumPhase.finding ||
              d.phase == AlbumPhase.importing) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: d.phase == AlbumPhase.downloading ? d.fraction : null,
                backgroundColor: SonarColors.surfaceElevated,
              ),
            ),
          ],
          if (d.phase == AlbumPhase.needsMatch && d.error != null) ...[
            const SizedBox(height: 8),
            Text(d.error!, style: text.bodySmall?.copyWith(color: SonarColors.textSecondary)),
          ],
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              if (d.active) TextButton(onPressed: () => downloads.cancel(d), child: const Text('Cancel')),
              if (d.phase == AlbumPhase.needsMatch) ...[
                TextButton(onPressed: () => showMatchPicker(context, d), child: const Text('Pick a match')),
                TextButton(
                  onPressed: () => downloads.importWith(d, const SbChooseAsIs()),
                  child: const Text('Import as it is'),
                ),
              ],
              if (d.phase == AlbumPhase.failed && (album != null || d.importFailed))
                TextButton(onPressed: () => downloads.tryAgain(d), child: const Text('Try again')),
              if (d.libraryAlbumId != null)
                TextButton(onPressed: () => context.openAlbum(d.libraryAlbumId!), child: const Text('Open album')),
            ],
          ),
        ],
      ),
    );
  }
}

// ---- Pick a match ------------------------------------------------------------------

Future<void> showMatchPicker(BuildContext context, AlbumDownload d) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 620),
  builder: (_) => _MatchPicker(d: d),
);

class _MatchPicker extends ConsumerWidget {
  const _MatchPicker({required this.d});
  final AlbumDownload d;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.read(soulbeetDownloadsProvider)!;
    final text = Theme.of(context).textTheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, scroll) => FutureBuilder<List<SbMatch>>(
        future: downloads.matches(d),
        builder: (context, snap) {
          final matches = snap.data ?? const <SbMatch>[];
          return ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 24),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
                child: Text('Which release is it?', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 4, SonarSpacing.gutter, 8),
                child: Text(
                  'beets found these. Pick the one you want it filed as.',
                  style: text.bodySmall?.copyWith(color: SonarColors.textSecondary),
                ),
              ),
              if (snap.connectionState != ConnectionState.done) const SkeletonRows(count: 5),
              if (snap.hasError) const ListTile(title: Text('Couldn\'t load the matches.')),
              for (final m in matches)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
                  title: Text('${m.title} — ${m.artist}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      if (m.year != null) '${m.year}',
                      ?m.country,
                      ?m.disambig,
                      if (m.matchedTracks != null) '${m.matchedTracks}/${m.totalTracks} songs',
                      '${(m.perMille / 10).round()}% match',
                    ].join(' · '),
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(downloads.importWith(d, SbChooseMatch(m)));
                  },
                ),
              const Divider(),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
                leading: const Icon(Icons.label_outline_rounded),
                title: const Text('Import as it is'),
                subtitle: const Text('Keep the tags the files came with'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(downloads.importWith(d, const SbChooseAsIs()));
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
