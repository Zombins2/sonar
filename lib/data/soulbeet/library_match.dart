import '../subsonic/models.dart';

/// Lower case, no brackets ("(Remastered)", "[Deluxe]"), "&" as "and", only
/// letters and digits: how album and artist names are compared.
String normaliseName(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ')
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// The album in the library that is [title] by [artist], if any. Artists match
/// when one name contains the other ("Bob Marley" / "Bob Marley & The Wailers").
Album? findLibraryAlbum(Iterable<Album> library, String title, String? artist) {
  final t = normaliseName(title);
  final a = artist == null ? '' : normaliseName(artist);
  if (t.isEmpty) return null;
  for (final album in library) {
    if (normaliseName(album.name) != t) continue;
    final have = normaliseName(album.artist);
    if (a.isEmpty || have.contains(a) || a.contains(have)) return album;
  }
  return null;
}
