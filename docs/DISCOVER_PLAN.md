# Discover: new songs downloaded for you, kept only if you want them

Status: plan, step 0 checks done, nothing built. Written 2026-11-15.

## What it does

Sonar picks songs you don't have by artists like the ones you play most
(the same picks as Get music's "Because you play…" rows), downloads them
through Soulbeet into a separate **Discover** folder, and mixes them into what
you listen to. Each one has two buttons: **Keep** moves it into your library,
**Remove** deletes it from the server. Songs you haven't decided on stay in
Discover until you do.

Keep / Remove exist only for Discover songs. The main library gets no
like/dislike system. (Sonar's existing Favourites heart is unrelated and
unchanged.)

## Decisions made

- **Songs, not albums.** For each suggested artist, their most popular one or
  two songs (Deezer's top tracks), downloaded with the song download Get music
  already has (`SoulbeetDownloads.download(album, songs: [...])`, which calls
  Soulbeet's `auto-download` with a track list). Nothing new to invent there,
  only a different folder.
- **Undecided songs are never removed by themselves.** When Discover is full,
  Sonar stops downloading and says so ("Discover is full: keep or remove some
  songs"). An optional setting, off unless you turn it on, makes room by
  removing the oldest undecided songs instead.
- **One Discover pool per server** for now (one listener). Per-user pools can
  come later if someone else uses the server.

## Settings (new "Discover" section)

- Discover on / off (off by default; only shown when Get music is set up).
- Limit: number of songs (default 50) or space (default 2 GB), whichever is
  hit first.
- New songs in autoplay: off / 1 in 5 / 1 in 3.
- Make room by removing the oldest undecided songs: off.

## How it fits the server

| Piece | Today | With Discover |
|---|---|---|
| Discover folder | none | a new folder outside the music folder (the installer's default: `Sonar Discover` next to it) |
| Soulbeet | imports into `/music` (= `Music\Soulbeet`) | also mounts the Discover folder at `/music-discover`; Sonar adds it as a second Soulbeet folder for its login. Soulbeet gives every folder its own beets database (`<folder>/.beets_library.db`), so Discover's beets library is separate |
| Navidrome | one library, `/music` read-only | a second library, **Discover**, at `/discover` (read-only); Navidrome 0.58+ has several libraries |
| Sonar Connect | no folders | mounts Discover and `Music\Soulbeet` read-write, plus a small volume for its own state |

Sonar Connect does the file work, because the app can't move or delete files
on the server and Navidrome has no API for it.

### Sonar Connect: new endpoints (same login sessions as today)

- `POST /discover/keep {songIds}`: for each Navidrome song id, Connect asks
  Navidrome's admin API (`/api/song/{id}`) for the song's library and real
  file path. It checks the song is in the Discover library and the resolved
  path is inside the Discover folder. It then moves the file to the same
  `Artist/Album/` path under `Music\Soulbeet` and moves its row from Discover's
  beets database to the main one (paths are relative, so the row copies
  unchanged). Finally it asks Navidrome to rescan. The song keeps its
  Navidrome id and play count.
- `POST /discover/remove {songIds}`: same lookup and checks, then deletes the
  file (and the album folder if it is left empty) and its beets row, records
  the song and artist as removed, rescans, and clears the song from
  Navidrome's missing-files list.
- At start-up, Connect creates the Navidrome Discover library if it's missing
  and grants it to Navidrome's users.
- `GET /discover/removed`: what was removed, so it isn't suggested again.

Safety rules, each with a test that proves it:

- The app sends song ids, never file paths. Connect finds the path itself.
- Connect refuses any file whose real path (after resolving links and `..`)
  isn't inside the Discover folder. It can't touch the main library except
  to add a kept song to it, and never overwrites a file that already exists
  there.
- Only logged-in Sonar sessions can call these endpoints.

## How it fits the app

1. **Topping up** (when the app opens and every few hours while open): count
   Discover songs and their size in Navidrome (the Discover library's
   `musicFolderId`), plus songs already downloading. While under the limit, take
   the next suggested artist, look up their top songs on Deezer, find each
   song's album the way Get music does (barcode → MusicBrainz → Soulbeet), and
   download just that song into the Discover folder. Skip anything removed
   before, anything already in the library, and artists with two or more
   removed songs. Downloads carry on on the server after the app closes.
2. **Keeping the library clean:** library screens (albums, artists, search,
   random, genres) ask Navidrome for the main library only, so Discover songs
   don't show up there until kept.
3. **Listening:**
   - a **Discover mix** in Home's "Made for you": Discover songs, shuffled;
   - a **Discover** screen listing undecided songs with Keep / Remove for each,
     and how full Discover is;
   - autoplay mixes in new songs at the rate set in Settings, marked "New".
4. **Keep / Remove** on the player screen and the Discover screen (phone and
   PC), with Undo for a few seconds before Remove is sent.

## Step 0 results (checked 2026-11-15)

Navidrome checks ran on a throwaway Navidrome 0.64.2 (the same image as the
server) with two test folders; beets checks ran inside the real Soulbeet
container on a copied file in `/tmp`, removed afterwards. Nothing on the real
server was changed.

1. **Navidrome, second library: works.**
   - Created through the admin API: `POST /api/library {"name":"Discover","path":"/discover"}`.
   - A new library is **not** given to ordinary users by itself. Grant it with
     `PUT /api/user/{id}/library {"libraryIds":[1,2]}` (numbers, not strings).
     Connect does both at start-up with its admin login.
   - With access, `getMusicFolders` lists both libraries. `musicFolderId` filters
     `getAlbumList2`, `getArtists`, `getRandomSongs`, `search3` and
     `getSongsByGenre`, and `getStarred2` accepts it.
   - `getSimilarSongs2` has no folder filter, and a Subsonic song carries no
     library field. The app learns which ids are Discover songs from
     `search3` with `query=""` and the Discover `musicFolderId`, and filters
     similar-song results against that list.
2. **Real file paths: from the admin API only.**
   - The Subsonic `path` is made up from tags (`01-01 - Police in Helicopter.flac`
     for a file really named `Police in Helicopter.flac`).
   - `GET /api/song/{id}` (admin) gives the real `path`, `libraryId` and
     `libraryPath`. Connect checks `libraryId` is Discover's as well as the
     resolved path.
   - **Moving a file from Discover into the main library and rescanning keeps
     the same song id, play count and Favourites heart.**
   - **Deleting a file** drops the song from every list, but Navidrome keeps it
     as "missing" (`getSong` still answers) until an admin clears it. Connect
     clears it right after the rescan with `DELETE /api/missing?id=<songId>`,
     after which `getSong` says "Song not found".
3. **Soulbeet files a single song into a second folder: works.**
   - Soulbeet's code imports every finished download into its target folder with
     that folder's own database (`beet -d <folder> -l <folder>/.beets_library.db`),
     and imports downloads as singletons (`-s`).
   - The same `beet` command with `beets\config.yaml` filed a copied song into a
     second library as `Junior Murvin/Police and Thieves/Police and Thieves.flac`,
     matched on MusicBrainz.
   - Not run: a real Soulseek download into `/music-discover`. That needs the
     new mount, so it's the first thing tested in the server step, with the
     owner's go-ahead.
4. **Moving a beets row between libraries: works, and simply.**
   - beets 2.11 stores paths relative to the library folder, so the `items` row
     and its `item_attributes` copy across unchanged.
   - Afterwards `beet ls` shows the song only in the main library, and
     `beet update -p` finds nothing to change in either.
   - Connect also removes the empty `Artist/Album` folders left in Discover.
     The tested script is a starting point for Connect's code.
5. **Deezer top songs: usable, with a fallback.**
   - `/artist/{id}/top` gives each song's album id, and the album has a barcode.
   - On MusicBrainz, 4 of 7 barcodes resolved: every full album did, but two
     singles and an older reissue didn't. Deezer also lists the same song on
     compilations.
   - So for each top song: take the studio album version (not a compilation)
     by barcode. Failing that, search MusicBrainz for the recording by title and
     artist (Soulbeet's `searchTracks`, already in the client). Skip the song if
     neither finds it.

### Found while building the server step

- **Song downloads are imported as part of their album, not as singletons.**
  - The server runs Soulbeet with `BEETS_ALBUM_MODE=true`. beets skips a lone
    song at first (most of the album is missing), and the app retries the
    import with the MusicBrainz release (`SbChooseRelease`; the driver's source
    name is `MusicBrainz`, with a capital B).
  - The result is an `items` row with an `albums` row, a `cover.jpg` beside the
    song, and an `artpath` flexible attribute holding Soulbeet's absolute path
    (`/music-discover/...`).
  - Connect moves the album row too: shared if the library already has that
    release, removed from Discover once its last song goes. It also rewrites
    `/music-discover/` to `/music/`. This was reproduced with Soulbeet's own
    import driver in the container.
- **The retry needs the app, while the download is happening.** Soulbeet's
  update feed only sends live changes and never replays finished rows. It
  keeps skipped imports in memory, not in its database, and the retry is
  addressed by the row's `item` (the sharer's file path). So once a Discover
  download's import is skipped with no app listening, nothing can retry it
  later. **Open problem for app part 1.** Options: keep the app following
  Discover downloads until each import ends; have Connect follow Soulbeet's
  feed for them; or import skipped downloads by hand from
  `/downloads/<batch>` with Soulbeet's import driver (what the live check
  below had to do).

### Live check on the owner's server (2026-11-15)

- Connect created the Discover library on start-up. The only Navidrome user
  is an admin, who sees every library already.
- One song, Toots & The Maytals' "Country Road" (*Funky Kingston*, release
  `a845f358-…`), was downloaded through Soulbeet into `/music-discover` with
  the app's own client (17 MB FLAC, seconds). Soulbeet's album-mode import
  skipped it ("No close match"), as expected. The test script missed the live
  retry, so it was imported with Soulbeet's driver and the release, which
  filed it as `Toots & The Maytals/Funky Kingston/08 Country Road.flac` with
  its cover.
- **First keep failed and left a copy behind.** Connect ran as user `relay`
  and couldn't delete the root-owned original. The cross-mount move had
  already copied the file into the library, so the song was in both places.
  The copy (byte-identical) and Navidrome's entry for it were removed by hand.
  - Fixed: moves now undo themselves (`_move`: copy, then delete the original,
    else remove the copy and any folders made). Two tests force the
    cross-mount path, and four mutations prove them.
  - Connect now runs as root in the compose file.
- **Second keep worked.** Same Navidrome song id, now in the main library and
  gone from Discover. The file and cover are under `Soulbeet/`. beets' main
  database has the song and its album, with `artpath` rewritten to `/music/…`.
  Discover's database is empty, and `beet update -p` finds nothing to change.
- The kept song stays in the owner's library.

### Soulbeet's own Discovery (found during step 0, not used)

Soulbeet has a Discovery feature that does much of this already:
- song-count targets per profile;
- Promote / Remove;
- Navidrome playlists;
- star ratings (3+ keeps a song, 1 deletes it).

It isn't used here because:
- it only gets ideas from Last.fm or ListenBrainz listening history, which
  needs an account (the owner doesn't want extra accounts);
- unrated songs expire after a set number of days (default 7);
- it files songs inside the main music folder (`<folder>/Discovery/<profile>`),
  so they'd mix into the main library.

Sonar's version needs no account and works from Navidrome's own play counts.

## Build order

1. **Step 0 checks**: done, results above.
2. **Server** (starts with one real song download into the new Discover
   folder): the Discover folder in the installer (Windows and Mac/Linux),
   mounts for Navidrome, Soulbeet and Connect, Connect's keep/remove/removed
   endpoints with tests, the Navidrome Discover library. Needs a restart of the
   `sonar` containers.
3. **App, part 1:** Settings section, the main-library-only filter on library
   screens, topping up, the Discover screen with Keep / Remove.
4. **App, part 2:** the Discover mix and new songs in autoplay.
5. **Release** as one version, with README notes: what Discover sends to
   Deezer (the same artist names as suggestions), and that it downloads from
   Soulseek by itself, within the limit, through the VPN.

## Not in this plan

- Like / dislike for the main library.
- Removing undecided songs on a timer.
- Separate pools per user.
