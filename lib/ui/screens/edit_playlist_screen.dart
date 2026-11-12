import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';

/// Rename, reorder, remove tracks, or delete a playlist. Nothing is sent to the
/// server until Save.
class EditPlaylistScreen extends ConsumerStatefulWidget {
  const EditPlaylistScreen({super.key, required this.playlist});
  final Playlist playlist;

  /// Returns true when the playlist was deleted.
  static Future<bool?> open(BuildContext context, Playlist playlist) => Navigator.of(
    context,
    rootNavigator: true,
  ).push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => EditPlaylistScreen(playlist: playlist)));

  @override
  ConsumerState<EditPlaylistScreen> createState() => _EditPlaylistScreenState();
}

class _EditPlaylistScreenState extends ConsumerState<EditPlaylistScreen> {
  late final _name = TextEditingController(text: widget.playlist.name);
  late final List<Song> _songs = List.of(widget.playlist.songs);

  /// One stable key per row (moved with it), since a playlist may hold the same song twice.
  late final List<int> _keys = List.generate(_songs.length, (i) => i);
  bool _saving = false;

  bool get _orderChanged {
    final before = widget.playlist.songs;
    if (before.length != _songs.length) return true;
    for (var i = 0; i < before.length; i++) {
      if (before[i].id != _songs[i].id) return true;
    }
    return false;
  }

  bool get _nameChanged => _name.text.trim().isNotEmpty && _name.text.trim() != widget.playlist.name;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(playlistProvider(widget.playlist.id));
    ref.invalidate(playlistsProvider);
  }

  Future<void> _save() async {
    final client = ref.read(clientProvider);
    if (client == null) return;
    setState(() => _saving = true);
    try {
      if (_orderChanged) await client.replacePlaylistSongs(widget.playlist.id, _songs.map((s) => s.id).toList());
      if (_nameChanged) await client.renamePlaylist(widget.playlist.id, _name.text.trim());

      // Keep a downloaded copy in step with the edit.
      final dm = ref.read(downloadManagerProvider);
      final saved = dm.collection('playlist', widget.playlist.id);
      if (saved != null) {
        await dm.downloadCollection(
          kind: 'playlist',
          sourceId: widget.playlist.id,
          title: _nameChanged ? _name.text.trim() : saved.title,
          subtitle: saved.subtitle,
          coverArt: saved.coverArt,
          songs: _songs,
        );
      }
      _refresh();
      if (mounted) Navigator.of(context).pop(false);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, errorText(e));
      }
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: SonarColors.surfaceElevated,
        title: const Text('Delete playlist?'),
        content: Text('"${widget.playlist.name}" will be deleted from your server.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Delete', style: TextStyle(color: Color(0xFFFF7A7A))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final client = ref.read(clientProvider);
    if (client == null) return;
    setState(() => _saving = true);
    try {
      await client.deletePlaylist(widget.playlist.id);
      await ref.read(downloadManagerProvider).removeCollection('playlist', widget.playlist.id);
      ref.invalidate(playlistsProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, errorText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dirty = _orderChanged || _nameChanged;
    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: const Text('Edit playlist'),
        actions: [
          TextButton(
            onPressed: dirty && !_saving ? _save : null,
            child: _saving
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 8, SonarSpacing.gutter, 16),
              child: TextField(
                controller: _name,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Name'),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 0, SonarSpacing.gutter, 8),
              child: Text('${_songs.length} songs · drag to reorder', style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          SliverReorderableList(
            itemCount: _songs.length,
            onReorder: (from, to) => setState(() {
              // ReorderableList reports `to` as the slot before removal.
              final target = to > from ? to - 1 : to;
              _songs.insert(target, _songs.removeAt(from));
              _keys.insert(target, _keys.removeAt(from));
            }),
            itemBuilder: (context, i) {
              final s = _songs[i];
              return Material(
                key: ValueKey(_keys[i]),
                color: SonarColors.background,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4, right: 4, top: 2, bottom: 2),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.remove_circle_rounded, color: Color(0xFFFF6B6B)),
                        onPressed: () => setState(() {
                          _songs.removeAt(i);
                          _keys.removeAt(i);
                        }),
                      ),
                      CoverArt(coverArt: s.coverArt, size: 44, radius: 6),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: SonarColors.textPrimary, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              s.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      ReorderableDragStartListener(
                        index: i,
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.drag_handle_rounded, color: SonarColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 32, SonarSpacing.gutter, 48),
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _delete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFF7A7A),
                  side: const BorderSide(color: Color(0x66FF7A7A)),
                  minimumSize: const Size.fromHeight(48),
                  shape: const StadiumBorder(),
                ),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Delete playlist'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
