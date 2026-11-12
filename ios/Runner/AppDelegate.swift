import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeDownloadsFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  /// Downloaded songs live in Application Support/music (see
  /// lib/downloads/download_manager.dart). iOS backs Application Support up to
  /// iCloud, which would fill the user's iCloud with music their server
  /// already has, so the folder is marked as not backed up.
  private func excludeDownloadsFromBackup() {
    let fm = FileManager.default
    guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    var music = support.appendingPathComponent("music", isDirectory: true)
    try? fm.createDirectory(at: music, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? music.setResourceValues(values)
  }
}
