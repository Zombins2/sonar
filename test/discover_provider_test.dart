// The app's one Discover (discoverProvider): it must outlive download
// progress. Watching the downloads' changes remade it on every progress
// event, each new one topping up again (seen live 2026-11-16: the Home row
// flashing on and off, and more downloads than a top-up's worth).
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/audio/audio_handler.dart';
import 'package:sonar/connect/connect_client.dart';
import 'package:sonar/connect/connect_link.dart';
import 'package:sonar/data/db/database.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_downloads.dart';
import 'package:sonar/data/subsonic/subsonic_client.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/state/soulbeet_providers.dart';

import 'support/fake_server.dart';
import 'support/player_harness.dart';

class _Session extends SessionNotifier {
  @override
  Future<ServerCredentials?> build() async => testCreds;
}

void main() {
  final harness = PlayerHarness();
  setUp(harness.setUp);
  tearDown(harness.tearDown);

  test('download progress leaves Discover as it is', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final handler = SonarAudioHandler(db);
    addTearDown(handler.dispose);
    final downloads = SoulbeetDownloads(
      client: SoulbeetClient(base: Uri.parse('http://127.0.0.1:9'), username: 'u', password: 'p'),
    );
    final connect = ConnectClient(
      base: Uri.parse('http://127.0.0.1:9'),
      me: const ConnectDeviceInfo(id: 'pc', name: 'PC', kind: 'pc'),
      loginProof: () => const {},
    );
    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        sessionProvider.overrideWith(_Session.new),
        soulbeetDownloadsProvider.overrideWith((_) => downloads),
        connectLinkProvider.overrideWithValue(ConnectLink(handler: handler, client: connect)),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(discoverProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(sessionProvider.future);
    final first = container.read(discoverProvider);
    expect(first, isNotNull);

    downloads.debugAdd(AlbumDownload.debug('b1', label: 'Country Road', forDiscover: true));
    await Future<void>.delayed(Duration.zero);
    expect(identical(container.read(discoverProvider), first), isTrue, reason: 'the same one, not a new one');
  });
}
