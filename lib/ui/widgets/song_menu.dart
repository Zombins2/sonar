import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/playback_source.dart';
import '../../audio/player_controls.dart';
import '../../core/nav.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/discovery.dart';
import '../../data/subsonic/models.dart';
import '../../data/subsonic/subsonic_client.dart';
import '../../state/providers.dart';
import 'common.dart';
import 'cover_art.dart';

/// Overflow menu for a track: Play next, Add to queue, Add to playlist,
/// Favorite, Go to album/artist.
Future<void> showSongMenu(BuildContext context, Song song, {bool hideAlbumLink = false}) {
  // Navigation must use a context that outlives the sheet.
  final router = GoRouter.of(context);
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheet) => Consumer(
      builder: (sheet, ref, _) {
        final starred = ref.watch(starredProvider).valueOrNull?.contains(song.id) ?? song.starred;
        final handler = ref.read(controlsProvider);

        void close() => Navigator.of(sheet).pop();
        void snack(String m) => messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: CoverArt(coverArt: song.coverArt, size: 48, radius: 6),
                  title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(height: 8),
                _item(Icons.playlist_play_rounded, 'Play next', () {
                  close();
                  handler.playNext([song]);
                  snack('Playing next');
                }),
                _item(Icons.queue_music_rounded, 'Add to queue', () {
                  close();
                  handler.addToQueue([song]);
                  snack('Added to queue');
                }),
                _item(Icons.playlist_add_rounded, 'Add to playlist', () {
                  close();
                  showAddToPlaylist(context, [song]);
                }),
                _item(Icons.radio_rounded, 'Start radio', () {
                  close();
                  playRadio(
                    handler,
                    ref.read(clientProvider),
                    PlaybackSource(SourceKind.radio, song.id, '${song.title} Radio'),
                    (client) => songRadio(client, song),
                    snack,
                  );
                }),
                // Desktop plays from the server next door; downloads are a phone thing.
                if (isDesktopPlatform)
                  const SizedBox.shrink()
                else if (ref.watch(downloadManagerProvider).collection('song', song.id) != null)
                  _item(Icons.download_done_rounded, 'Remove download', () {
                    close();
                    ref.read(downloadManagerProvider).removeCollection('song', song.id);
                    snack('Download removed');
                  })
                else if (!ref.watch(downloadManagerProvider.select((m) => m.isDownloaded(song.id))))
                  _item(Icons.download_rounded, 'Download', () {
                    close();
                    if (!ref.read(reachableProvider)) {
                      return snack('Server unreachable. Reconnect to download.');
                    }
                    ref
                        .read(downloadManagerProvider)
                        .downloadCollection(
                          kind: 'song',
                          sourceId: song.id,
                          title: song.title,
                          subtitle: song.artist,
                          coverArt: song.coverArt,
                          songs: [song],
                        );
                    snack('Downloading…');
                  }),
                _item(
                  starred ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  starred ? 'Remove from favorites' : 'Favorite',
                  () async {
                    close();
                    try {
                      await ref.read(starredProvider.notifier).toggleSong(song.id);
                    } catch (e) {
                      snack(errorText(e));
                    }
                  },
                ),
                if (!hideAlbumLink && song.albumId != null)
                  _item(Icons.album_rounded, 'Go to album', () {
                    close();
                    openInShell(router, (b) => '/$b/album/${song.albumId}');
                  }),
                if (song.artistId != null)
                  _item(Icons.person_rounded, 'Go to artist', () {
                    close();
                    openInShell(router, (b) => '/$b/artist/${song.artistId}');
                  }),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Builds a radio queue with [build] and plays it. Takes the handler and
/// client up front, since the menu that asked is usually gone by now.
Future<void> playRadio(
  PlayerControls handler,
  SubsonicClient? client,
  PlaybackSource source,
  Future<List<Song>> Function(SubsonicClient client) build,
  void Function(String message) snack,
) async {
  if (client == null) return;
  HapticFeedback.selectionClick();
  snack('Starting ${source.title}…');
  try {
    final songs = await build(client);
    if (songs.isEmpty) return snack('Nothing similar found in your library.');
    await handler.playSongs(songs, source: source);
  } catch (e) {
    snack(errorText(e));
  }
}

String? _firstSegment(GoRouter router) =>
    router.state.matchedLocation.split('/').where((s) => s.isNotEmpty).firstOrNull;

String _branchOf(GoRouter router) {
  final first = _firstSegment(router);
  return shellBranches.contains(first) ? first! : 'home';
}

/// Pops full-screen routes (Now Playing, Queue) first, so the detail page opens
/// inside the tab underneath instead of on top of the player.
void openInShell(GoRouter router, String Function(String branch) path) {
  if (!shellBranches.contains(_firstSegment(router))) {
    if (router.canPop()) router.pop();
    router.push(path(currentShellBranch.value));
    return;
  }
  router.push(path(_branchOf(router)));
}

Widget _item(IconData icon, String label, VoidCallback onTap) => ListTile(
  leading: Icon(icon, color: SonarColors.textPrimary),
  title: Text(label),
  onTap: onTap,
  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
);

/// Pick an existing playlist or create a new one containing [songs].
Future<void> showAddToPlaylist(BuildContext context, List<Song> songs) {
  final messenger = ScaffoldMessenger.of(context);
  void snack(String m) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheet) => Consumer(
      builder: (sheet, ref, _) {
        final playlists = ref.watch(playlistsProvider);
        final client = ref.read(clientProvider);
        final ids = songs.map((s) => s.id).toList();
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.7),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text('Add to playlist', style: Theme.of(sheet).textTheme.titleLarge),
                ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  leading: const Icon(Icons.add_rounded),
                  title: const Text('New playlist'),
                  onTap: () async {
                    final name = await _askName(sheet);
                    if (name == null || client == null) return;
                    try {
                      await client.createPlaylist(name, songIds: ids);
                      ref.invalidate(playlistsProvider);
                      if (sheet.mounted) Navigator.of(sheet).pop();
                      snack('Created "$name"');
                    } catch (e) {
                      snack(errorText(e));
                    }
                  },
                ),
                Flexible(
                  child: playlists.when(
                    loading: () => const Padding(padding: EdgeInsets.all(24), child: LoadingState()),
                    error: (e, _) => Padding(padding: const EdgeInsets.all(24), child: Text(errorText(e))),
                    data: (list) => ListView(
                      shrinkWrap: true,
                      children: [
                        for (final p in list)
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                            leading: CoverArt(
                              coverArt: p.coverArt,
                              size: 44,
                              radius: 6,
                              icon: Icons.queue_music_rounded,
                            ),
                            title: Text(p.name),
                            subtitle: Text('${p.songCount} songs'),
                            onTap: () async {
                              if (client == null) return;
                              try {
                                await client.addToPlaylist(p.id, ids);
                                ref.invalidate(playlistsProvider);
                                ref.invalidate(playlistProvider(p.id));
                                if (sheet.mounted) Navigator.of(sheet).pop();
                                snack('Added to ${p.name}');
                              } catch (e) {
                                snack(errorText(e));
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<String?> _askName(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      backgroundColor: SonarColors.surfaceElevated,
      title: const Text('New playlist'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (v) => Navigator.of(d).pop(v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(d).pop(), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            final v = controller.text.trim();
            Navigator.of(d).pop(v.isEmpty ? null : v);
          },
          child: const Text('Create'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Long-press actions for an album or playlist card, without opening it.
/// Tracks are fetched only when an action needs them.
Future<void> showCollectionQuickActions(
  BuildContext context, {
  required String kind,
  required String id,
  required String title,
  required String subtitle,
  String? coverArt,
  String? artistId,
}) {
  HapticFeedback.mediumImpact();
  final router = GoRouter.of(context);
  final messenger = ScaffoldMessenger.of(context);
  void snack(String m) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheet) => Consumer(
      builder: (sheet, ref, _) {
        final handler = ref.read(controlsProvider);
        final source = PlaybackSource(kind == 'album' ? SourceKind.album : SourceKind.playlist, id, title);

        Future<List<Song>> load() async {
          final client = requireClientOf(ref);
          return kind == 'album' ? (await client.getAlbum(id)).songs : (await client.getPlaylist(id)).songs;
        }

        Widget action(IconData icon, String label, Future<void> Function(List<Song> songs) run) =>
            _item(icon, label, () async {
              Navigator.of(sheet).pop();
              try {
                final songs = await load();
                if (songs.isNotEmpty) await run(songs);
              } catch (e) {
                snack(errorText(e));
              }
            });

        final downloaded = ref.watch(downloadManagerProvider).collection(kind, id) != null;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: CoverArt(coverArt: coverArt, size: 48, radius: 6),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(height: 8),
                action(Icons.play_arrow_rounded, 'Play', (s) => handler.playSongs(s, source: source)),
                action(Icons.shuffle_rounded, 'Shuffle', (s) => handler.playSongs(s, shuffle: true, source: source)),
                action(Icons.playlist_play_rounded, 'Play next', (s) async {
                  await handler.playNext(s);
                  snack('Playing next');
                }),
                action(Icons.queue_music_rounded, 'Add to queue', (s) async {
                  await handler.addToQueue(s);
                  snack('Added to queue');
                }),
                action(Icons.playlist_add_rounded, 'Add to playlist', (s) async {
                  if (context.mounted) await showAddToPlaylist(context, s);
                }),
                if (!downloaded && !isDesktopPlatform)
                  action(Icons.download_rounded, 'Download', (s) async {
                    if (!ref.read(reachableProvider)) {
                      return snack('Server unreachable. Reconnect to download.');
                    }
                    await ref
                        .read(downloadManagerProvider)
                        .downloadCollection(
                          kind: kind,
                          sourceId: id,
                          title: title,
                          subtitle: subtitle,
                          coverArt: coverArt,
                          songs: s,
                        );
                    snack('Downloading "$title"');
                  }),
                if (artistId != null)
                  _item(Icons.person_rounded, 'Go to artist', () {
                    Navigator.of(sheet).pop();
                    openInShell(router, (b) => '/$b/artist/$artistId');
                  }),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<void> showAlbumQuickActions(BuildContext context, Album a) => showCollectionQuickActions(
  context,
  kind: 'album',
  id: a.id,
  title: a.name,
  subtitle: a.artist,
  coverArt: a.coverArt,
  artistId: a.artistId,
);

Future<void> showPlaylistQuickActions(BuildContext context, Playlist p) => showCollectionQuickActions(
  context,
  kind: 'playlist',
  id: p.id,
  title: p.name,
  subtitle: '${p.songCount} songs',
  coverArt: p.coverArt,
);

/// Album/playlist-level actions: queue the whole set or add it to a playlist.
Future<void> showCollectionMenu(BuildContext context, WidgetRef ref, List<Song> songs, {String? artistId}) {
  final handler = ref.read(controlsProvider);
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _item(Icons.playlist_play_rounded, 'Play next', () {
            Navigator.of(sheet).pop();
            handler.playNext(songs);
            messenger.showSnackBar(const SnackBar(content: Text('Playing next')));
          }),
          _item(Icons.queue_music_rounded, 'Add to queue', () {
            Navigator.of(sheet).pop();
            handler.addToQueue(songs);
            messenger.showSnackBar(const SnackBar(content: Text('Added to queue')));
          }),
          _item(Icons.playlist_add_rounded, 'Add to playlist', () {
            Navigator.of(sheet).pop();
            showAddToPlaylist(context, songs);
          }),
          if (artistId != null)
            _item(Icons.person_rounded, 'Go to artist', () {
              Navigator.of(sheet).pop();
              context.openArtist(artistId);
            }),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
