import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/soulbeet/soulbeet_downloads.dart';
import '../../data/soulbeet/soulbeet_models.dart';
import '../../data/soulbeet/source_pick.dart';
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search(String v) => setState(() => _query = v.trim());

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
                        onSubmitted: _search,
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w500),
                        cursorColor: Colors.black,
                        decoration: InputDecoration(
                          fillColor: Colors.white,
                          hintText: 'Album, or Artist - Album',
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
        title: 'Find an album to add',
        message: 'Searches MusicBrainz. Sonar downloads the best FLAC copy it can find and files it in your library.',
      );
    }
    final results = ref.watch(soulbeetAlbumSearchProvider(_query));
    return results.when(
      loading: () => const SkeletonRows(art: true),
      error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(soulbeetAlbumSearchProvider(_query))),
      data: (albums) => albums.isEmpty
          ? EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Nothing on MusicBrainz for "$_query"',
              message: 'Try the album name alone, or Artist - Album.',
            )
          : ListView.builder(
              padding: EdgeInsets.only(bottom: bottomInset(context)),
              itemCount: albums.length,
              itemBuilder: (_, i) => GetAlbumTile(album: albums[i]),
            ),
    );
  }
}

/// A MusicBrainz album's cover (Cover Art Archive), or a placeholder.
class MbCover extends ConsumerWidget {
  const MbCover({super.key, required this.mbid, this.size = 56, this.radius = 6});
  final String? mbid;
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
    Widget image;
    if (mbid == null) {
      image = placeholder;
    } else if (override != null) {
      image = Image(image: override('mb:$mbid'), fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
    } else {
      image = CachedNetworkImage(
        imageUrl: 'https://coverartarchive.org/release/$mbid/front-${size > 120 ? 500 : 250}',
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
    final d = ref.watch(soulbeetDownloadsProvider)?.forAlbum(album.id);
    final subtitle = [album.artist, ?album.year].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter, vertical: 2),
      leading: MbCover(mbid: album.mbid),
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

Future<void> showAlbumSheet(BuildContext context, SbAlbum album) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 620),
  builder: (_) => _AlbumSheet(album: album),
);

class _AlbumSheet extends ConsumerWidget {
  const _AlbumSheet({required this.album});
  final SbAlbum album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final detail = ref.watch(soulbeetAlbumDetailProvider(album.id));
    final downloads = ref.watch(soulbeetDownloadsProvider);
    final owned = ref.watch(libraryAlbumForProvider((title: album.title, artist: album.artist))).valueOrNull;
    final d = downloads?.forAlbum(album.id);
    final tracks = detail.valueOrNull?.tracks ?? const <SbTrack>[];
    final length = tracks.fold(Duration.zero, (s, t) => s + (t.duration ?? Duration.zero));

    Future<void> download({SbSource? chosen}) async {
      final nav = Navigator.of(context);
      final messenger = ScaffoldMessenger.maybeOf(context);
      nav.pop();
      final started = await downloads!.download(
        album,
        trackCount: tracks.isEmpty ? null : tracks.length,
        chosen: chosen,
      );
      if (started.phase == AlbumPhase.failed) {
        messenger?.showSnackBar(SnackBar(content: Text(started.error ?? 'Couldn\'t start the download.')));
      }
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
              MbCover(mbid: album.mbid, size: 112, radius: 8),
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
          if (d != null) ...[
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
          ] else if (owned != null) ...[
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
                OutlinedButton(onPressed: download, child: const Text('Download anyway')),
              ],
            ),
          ] else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  style: _inline,
                  onPressed: downloads == null ? null : download,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Download'),
                ),
                OutlinedButton.icon(
                  onPressed: downloads == null
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
          const SizedBox(height: 20),
          if (detail.isLoading) const SkeletonRows(count: 6),
          if (detail.hasError) Text('Couldn\'t load the songs.', style: text.bodySmall),
          for (final (i, t) in tracks.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text('${i + 1}', style: text.bodySmall?.copyWith(color: SonarColors.textSecondary)),
                  ),
                  Expanded(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (t.duration != null)
                    Text(
                      '${t.duration!.inMinutes}:${(t.duration!.inSeconds % 60).toString().padLeft(2, '0')}',
                      style: text.bodySmall?.copyWith(color: SonarColors.textSecondary),
                    ),
                ],
              ),
            ),
        ],
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
                    Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleMedium),
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
