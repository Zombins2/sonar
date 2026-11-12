import '../data/subsonic/models.dart';
import 'playback_source.dart';

/// What the screens can ask of a player: the one on this device
/// ([SonarAudioHandler]) or another device's, through Sonar Connect.
///
/// Queue indices are positions in the queue the screens are shown
/// (`queueProvider`), whichever player that is.
abstract interface class PlayerControls {
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> skipToNext();
  Future<void> skipToPrevious();
  Future<void> skipToPreviousTrack();
  Future<void> skipToQueueItem(int index);
  Future<void> playSongs(
    List<Song> songs, {
    int index = 0,
    bool shuffle = false,
    PlaybackSource? source,
    Duration position = Duration.zero,
  });
  Future<void> playNext(List<Song> songs);
  Future<void> addToQueue(List<Song> songs);
  Future<void> removeQueueItemAt(int index);
  Future<void> moveQueueItem(int from, int to);
  Future<void> toggleShuffle();
  Future<void> cycleRepeat();
  void setUserVolume(double v);

  /// The song playing, as a full song (for its menu).
  Song? get currentSong;
}
