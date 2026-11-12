# Get Music: Soulbeet inside Sonar

Search for albums you don't have, download them, and watch them arrive, from
Sonar on the phone and the PC. Sonar talks to the Soulbeet server that already
runs beside Navidrome (search on MusicBrainz, download over Soulseek through
the Proton VPN, tag and file with beets). Nothing about Soulseek or the VPN
moves into the app.

## What the server offers (recorded, not guessed)

Soulbeet v0.8.0 (image pinned). The web page is a client of an HTTP API made of
Dioxus server functions. Every shape below comes from a recording of the real
server (`test/fixtures/soulbeet/*.json`, peers renamed `peer1`..., tokens
redacted) or, where marked, from the v0.8.0 source.

Base URL: `https://<navidrome host>:8443` over Tailscale (Tailscale serve
-> 127.0.0.1:9765); `http://127.0.0.1:9765` when Sonar runs on the server PC.

Calls are `POST` with a JSON object keyed by the Rust argument name
(`{"input": {...}}`, `{"data": {...}}`, `{"req": {...}}`). Replies are JSON.
Errors come back as non-200 with a text body.

| Purpose | Call | Body -> reply |
|---|---|---|
| Log in | `POST /api/auth/login` | `{"username","password"}` -> `{username,user_id,navidrome_status}` + `Set-Cookie: auth_token=<JWT>` (HttpOnly, 30 days). *From source; the login itself was not recorded.* |
| Renew | `POST /api/auth/refresh` | cookie -> new cookie |
| Who am I | `GET /api/auth/me` | `{username,user_id,navidrome_status}`; 401 when logged out (`auth_me_logged_out.json`) |
| Is it working | `GET /api/system/health` | `{downloader_online, importer:{level,issues,facts}, navidrome_online}` |
| Library folders | `GET /api/folders` | `[{id, path:"/music", name, ...}]` (download target) |
| Album search | `POST /api/metadata/search/album` | `{"input":{"query","artist"\|null,"provider":"musicbrainz"}}` -> `{provider, results:[{kind:"Album",id,title,artist,release_date,mbid}]}` |
| Track search | `POST /api/metadata/search/track` | same shape, `kind:"Track"` |
| Album tracks | `POST /api/metadata/album` | `{"input":{"id","provider"}}` -> `{album:{...}, tracks:[{id,title,artist,album_id,album_title,duration:"04:41",mbid,release_mbid}]}` |
| Download (Soulbeet picks the source) | `POST /api/auto-download` | `{"req":{"query":{"album":{...},"tracks":[],"backend":null},"folder_id","folder_path":"/music"}}` -> `{"Accepted":{"batch_id"}}` or `{"Error":"..."}` |
| Find sources (no download) | `POST /api/download/search/start` | `{"data":{"album":{...},"tracks":[],"backend":null}}` -> `"<search_id>"` |
| ... poll | `POST /api/download/search/poll` | `{"input":{"search_id","backend":null}}` -> `{search_id, groups:[{source,title,artist,item_count,total_size,quality,score,items:[...]}], has_more, state:"InProgress"\|"Completed"\|"NotFound"\|"TimedOut"}`; each item's `backend_data` is a JSON string with `hasFreeUploadSlot`, `uploadSpeed`, `queueLength`, `bitDepth`, `sampleRate` |
| Download a chosen source | `POST /api/downloads/queue` | `{"req":{"items":[DownloadableItem],"target_folder":"/music","backend":null}}` -> `[{id,source,item,size,status}]` *(source)* |
| Live progress | `GET /api/downloads/updates` (WebSocket, cookie auth) | binary frames holding JSON `DownloadEvent`s (below) |
| Cancel | `POST /api/downloads/cancel` | `{"req":{"id","source","item","backend"}}` *(source)* |
| Matches for a skipped import | `POST /api/downloads/import-choices` | `{"item":"<row item>"}` -> `{kind:"Album", candidates:[{data_source,id,artist,title,year,country,disambig,per_mille,differs,tracks:{matched,total,extra_files}}]}` |
| Import again | `POST /api/downloads/retry-import` | `{"item", "choice": "Auto" \| "AsIs" \| {"Candidate":{data_source,id}} \| {"MusicBrainz":"<release id>"}}` -> `null` (then `Importing` -> `Imported` on the WebSocket) |

`DownloadEvent` frames (recorded in `downloads_updates_ws.json`):
- `{"AutoDownload":{"Searching":{batch_id,query,backend_count}}}`, then
  `ScoringResults {result_count,best_score}`, `PickedSource {source,score,quality,track_count}`,
  `Downloading {batch_id}`, or `FallbackToManual` / `Failed {error}`.
- `{"Progress":[DownloadProgress]}`: one entry per file, `{id,source,item,size,transferred,
  state,percent,speed,error,batch_id,batch_label,local_path,import_output,retryable,can_choose_import}`.
  `state` is `"Queued"`, `"InProgress"`, `"Completed"`, `{"ImportQueued":n}`, `"Importing"`,
  `"Imported"`, `"ImportSkipped"`, `{"Failed":"why"}` or `"Cancelled"`.
- `{"Replaced":{...}}` *(source)*.

Things the recording showed that change the design:
- Soulbeet's own pick took an **M4A** copy over several FLAC copies with the
  same score (`PickedSource quality:"m4a"`).
- In album mode beets **skipped** the import ("No close match (8 candidates)"):
  five pressings fit 9/9 tracks at 88%, so it wouldn't guess, and the release
  that was searched for wasn't among its eight. Retrying with
  `{"MusicBrainz":"<the searched release id>"}` imported it at once. So when an
  import is skipped, Sonar retries with the release you picked, by itself;
  only if that fails does it ask you ("Pick a match", or "Import as it is").
- Soulbeet only asks Navidrome to rescan for its Discovery playlists, and
  Navidrome's `startScan` needs an admin, which the app's login is not. So a
  finished album does not show up in Sonar until Navidrome's next hourly scan.

## Decisions (owner chose both recommendations, 2026-11-12)

1. **Which copy:** Sonar runs the source search itself and takes the best complete
   **lossless** copy (`pickSource`: score >= 0.9, every track, then a free slot, a
   short queue, speed, score), queues it with `/api/downloads/queue`, and falls back
   to Soulbeet's pick when there is none. "Choose source" lists every copy.
2. **New albums in Navidrome:** the Sonar Connect relay has `POST /rescan` (a Sonar
   session, no arguments) and starts a scan with a Navidrome admin login from
   `server/sonar_connect/.env` (`NAVIDROME_ADMIN_USER`, `NAVIDROME_ADMIN_PASSWORD`;
   the owner types it). At most one scan per 10 s. Without the login it answers 503
   and albums wait for the hourly scan.

## What was built

Data (`lib/data/soulbeet/`):
- `soulbeet_client.dart`: login with the Navidrome username + password Sonar already
  holds (once, in a POST body over HTTPS/loopback; never in a URL, never logged); the
  `auth_token` cookie is kept in secure storage (`CredentialsStore.soulbeetToken`) and
  renewed on a 401. Every call above; the WebSocket uses `dart:io` with the cookie.
  Address: `soulbeetBaseFor` (same Tailscale name, port 8443; loopback -> 127.0.0.1:9765).
- `soulbeet_models.dart`: typed replies, lenient about extra fields, loud about missing
  needed ones (`SoulbeetFormatException` names the field).
- `source_pick.dart`: the copy Sonar picks.
- `soulbeet_downloads.dart`: the flow per album (find -> download -> import ->
  imported), the live feed (reconnects while anything is active, closes 2 min after),
  one automatic retry of a skipped import with the release picked, then the user
  picks; on import, `/rescan` and a search for the album in Navidrome for "Open album".
- `library_match.dart`: "In your library" by normalised title + artist.

UI (`lib/ui/screens/get_music_screen.dart`, providers in `lib/state/soulbeet_providers.dart`):
- Phone: "Get music" in the Search header, and "Get <query>" under library results or
  when there are none. PC: "Get music" in the sidebar (badge = albums on their way).
- Get music search ("Album" or "Artist - Album"), album sheet (songs, Download,
  Choose source), Downloads page (progress, speed, Cancel, Pick a match, Import as
  it is, Try again, Open album). Only shown when Soulbeet answers.

Tests: `test/soulbeet_test.dart` (fixtures, client vs `test/support/fake_soulbeet.dart`,
picking), `test/soulbeet_downloads_test.dart` (the flow, replaying events),
`test/connect_test.dart` + relay unittests (rescan), renders `test/visual/get_music_screens_test.dart`.
Every rule mutation-checked (30 app, 4 relay).

Known: MusicBrainz album search returns no release dates, and an album name alone
ranks obscure albums first ("Exodus" -> Bob Marley is 7th); "Artist - Album" fixes it.
Later: "Get album" on artist pages and "Fans also like" for music not in the library.

Not in scope: Soulbeet's Discovery, its settings (folders, users), and anything about
Soulseek, slskd or the VPN, which stay on the server.
