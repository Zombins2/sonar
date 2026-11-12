import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Running as a desktop app. Read from [defaultTargetPlatform], so tests can
/// switch it with `debugDefaultTargetPlatformOverride`.
bool get isDesktopPlatform =>
    const {TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}.contains(defaultTargetPlatform);

/// Windows at least this wide get the desktop layout: a sidebar, a full
/// player bar and side panels instead of tabs and a mini player.
const desktopBreakpoint = 900.0;

bool isWideLayout(BuildContext context) => MediaQuery.sizeOf(context).width >= desktopBreakpoint;
