-- beets 2.11 library schema, dumped from the Soulbeet image (docccccc/soulbeet:full).
CREATE TABLE album_attributes (
                    id INTEGER PRIMARY KEY,
                    entity_id INTEGER,
                    key TEXT,
                    value TEXT,
                    UNIQUE(entity_id, key) ON CONFLICT REPLACE);
CREATE TABLE albums (added REAL, album TEXT, albumartist TEXT, albumartist_credit TEXT, albumartist_sort TEXT, albumartists TEXT, albumartists_credit TEXT, albumartists_sort TEXT, albumdisambig TEXT, albumstatus TEXT, albumtype TEXT, albumtypes TEXT, artpath BLOB, asin TEXT, barcode TEXT, catalognum TEXT, comp INTEGER, country TEXT, day INTEGER, discogs_albumid INTEGER, discogs_artistid INTEGER, discogs_labelid INTEGER, disctotal INTEGER, genres TEXT, id INTEGER PRIMARY KEY, label TEXT, language TEXT, mb_albumartistid TEXT, mb_albumartistids TEXT, mb_albumid TEXT, mb_releasegroupid TEXT, month INTEGER, original_day INTEGER, original_month INTEGER, original_year INTEGER, r128_album_gain REAL, release_group_title TEXT, releasegroupdisambig TEXT, rg_album_gain REAL, rg_album_peak REAL, script TEXT, style TEXT, year INTEGER);
CREATE TABLE item_attributes (
                    id INTEGER PRIMARY KEY,
                    entity_id INTEGER,
                    key TEXT,
                    value TEXT,
                    UNIQUE(entity_id, key) ON CONFLICT REPLACE);
CREATE TABLE items (acoustid_fingerprint TEXT, acoustid_id TEXT, added REAL, album TEXT, album_id INTEGER, albumartist TEXT, albumartist_credit TEXT, albumartist_sort TEXT, albumartists TEXT, albumartists_credit TEXT, albumartists_sort TEXT, albumdisambig TEXT, albumstatus TEXT, albumtype TEXT, albumtypes TEXT, arrangers TEXT, arrangers_ids TEXT, artist TEXT, artist_credit TEXT, artist_sort TEXT, artists TEXT, artists_credit TEXT, artists_ids TEXT, artists_sort TEXT, asin TEXT, barcode TEXT, bitdepth INTEGER, bitrate INTEGER, bitrate_mode TEXT, bpm INTEGER, catalognum TEXT, channels INTEGER, comments TEXT, comp INTEGER, composer_sort TEXT, composers TEXT, composers_ids TEXT, country TEXT, day INTEGER, disc INTEGER, discogs_albumid INTEGER, discogs_artistid INTEGER, discogs_labelid INTEGER, disctitle TEXT, disctotal INTEGER, encoder TEXT, encoder_info TEXT, encoder_settings TEXT, format TEXT, genres TEXT, grouping TEXT, id INTEGER PRIMARY KEY, initial_key TEXT, isrc TEXT, label TEXT, language TEXT, length REAL, lyricists TEXT, lyricists_ids TEXT, lyrics TEXT, mb_albumartistid TEXT, mb_albumartistids TEXT, mb_albumid TEXT, mb_artistid TEXT, mb_artistids TEXT, mb_releasegroupid TEXT, mb_releasetrackid TEXT, mb_trackid TEXT, mb_workid TEXT, media TEXT, month INTEGER, mtime REAL, original_day INTEGER, original_month INTEGER, original_year INTEGER, path BLOB, r128_album_gain REAL, r128_track_gain REAL, release_group_title TEXT, releasegroupdisambig TEXT, remixers TEXT, remixers_ids TEXT, rg_album_gain REAL, rg_album_peak REAL, rg_track_gain REAL, rg_track_peak REAL, samplerate INTEGER, script TEXT, style TEXT, subtitle TEXT, title TEXT, track INTEGER, trackdisambig TEXT, tracktotal INTEGER, work TEXT, work_disambig TEXT, year INTEGER);
CREATE TABLE migrations (
                    name TEXT NOT NULL,
                    table_name TEXT NOT NULL,
                    PRIMARY KEY(name, table_name)
                );
CREATE INDEX album_attributes_by_entity
                    ON album_attributes (entity_id);
CREATE INDEX idx_item_album_id ON items (album_id);
CREATE INDEX item_attributes_by_entity
                    ON item_attributes (entity_id);
