// Starting and stopping the real app cleanly between runs: a run that fails
// part-way must not leave its login or queue for the next one.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/main.dart' as app;
import 'package:sonar/state/providers.dart';

typedef Until = Future<void> Function(bool Function() done, String what, {Duration timeout});

class AppHarness {
  AppHarness(this.tester);
  final WidgetTester tester;
  late final ProviderContainer container;

  /// Extra lines for a timeout message.
  String Function() describe = () => '';

  Future<void> until(bool Function() done, String what, {Duration timeout = const Duration(seconds: 20)}) async {
    final clock = Stopwatch()..start();
    while (!done()) {
      if (clock.elapsed > timeout) fail('timed out waiting for $what\n${describe()}');
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Launches the app and leaves it signed out, with no queue.
  Future<void> launch() async {
    await app.main();
    await tester.pump(const Duration(seconds: 1));
    container = ProviderScope.containerOf(tester.element(find.byType(app.SonarApp)));
    await until(() => !container.read(sessionProvider).isLoading, 'the saved session');
    await signOut();
  }

  /// Signs out and waits for the queue to be gone, here and on disk.
  Future<void> signOut() async {
    final handler = container.read(audioHandlerProvider);
    handler.setUserVolume(1);
    await handler.pause();
    if (container.read(sessionProvider).valueOrNull != null) {
      await container.read(sessionProvider.notifier).logout();
    }
    await until(() => handler.currentSong == null, 'the queue to clear');
    await tester.pump(const Duration(milliseconds: 700)); // A pending save lands.
    await container.read(dbProvider).clearAll();
  }
}
