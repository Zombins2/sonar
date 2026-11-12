import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum PlayerShortcut {
  playPause,
  next,
  previous,
  seekForward,
  seekBack,
  volumeUp,
  volumeDown,
  search,
  shuffle,
  repeat,
  close,
}

/// The desktop keys, also listed in Settings.
const playerShortcuts = <SingleActivator, PlayerShortcut>{
  SingleActivator(LogicalKeyboardKey.space): PlayerShortcut.playPause,
  SingleActivator(LogicalKeyboardKey.arrowRight, control: true): PlayerShortcut.next,
  SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): PlayerShortcut.previous,
  SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): PlayerShortcut.seekForward,
  SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): PlayerShortcut.seekBack,
  SingleActivator(LogicalKeyboardKey.arrowUp, control: true): PlayerShortcut.volumeUp,
  SingleActivator(LogicalKeyboardKey.arrowDown, control: true): PlayerShortcut.volumeDown,
  SingleActivator(LogicalKeyboardKey.keyF, control: true): PlayerShortcut.search,
  SingleActivator(LogicalKeyboardKey.keyL, control: true): PlayerShortcut.search,
  SingleActivator(LogicalKeyboardKey.keyS, control: true): PlayerShortcut.shuffle,
  SingleActivator(LogicalKeyboardKey.keyR, control: true): PlayerShortcut.repeat,
  SingleActivator(LogicalKeyboardKey.escape): PlayerShortcut.close,
};

/// Labels for the Settings list.
const playerShortcutHelp = [
  ('Space', 'Play / pause'),
  ('Ctrl + → / ←', 'Next / previous song'),
  ('Shift + → / ←', 'Forward / back 10 seconds'),
  ('Ctrl + ↑ / ↓', 'Volume up / down'),
  ('Ctrl + F', 'Search'),
  ('Ctrl + S', 'Shuffle'),
  ('Ctrl + R', 'Repeat'),
  ('Esc', 'Close Now Playing'),
];

class _PlayerIntent extends Intent {
  const _PlayerIntent(this.shortcut);
  final PlayerShortcut shortcut;
}

/// Turns [playerShortcuts] into calls to [onShortcut] anywhere below it,
/// except while a text field has focus (so Space still types a space).
class DesktopShortcuts extends StatelessWidget {
  const DesktopShortcuts({super.key, required this.onShortcut, required this.child});
  final void Function(PlayerShortcut) onShortcut;
  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: {for (final e in playerShortcuts.entries) e.key: _PlayerIntent(e.value)},
    child: Actions(
      actions: {_PlayerIntent: _PlayerAction(onShortcut)},
      // Something below must hold focus for the keys to arrive here.
      child: Focus(autofocus: true, child: child),
    ),
  );
}

class _PlayerAction extends Action<_PlayerIntent> {
  _PlayerAction(this.onShortcut);
  final void Function(PlayerShortcut) onShortcut;

  static bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  // Disabled while typing: the key then goes on to the text field.
  @override
  bool isEnabled(_PlayerIntent intent) => !_typing;

  @override
  Object? invoke(_PlayerIntent intent) {
    onShortcut(intent.shortcut);
    return null;
  }
}
