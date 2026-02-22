import Flutter
import UIKit
import YandexMapsMobile

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let apiKey = readYandexApiKey(), !apiKey.isEmpty {
      YMKMapKit.setApiKey(apiKey)
      YMKMapKit.setLocale("ru_RU")
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func readYandexApiKey() -> String? {
    let paths = [
      Bundle.main.path(forResource: ".env", ofType: nil, inDirectory: "flutter_assets"),
      Bundle.main.path(
        forResource: ".env",
        ofType: nil,
        inDirectory: "Frameworks/App.framework/flutter_assets"
      )
    ]

    for path in paths {
      guard let filePath = path else { continue }
      guard let content = try? String(contentsOfFile: filePath) else { continue }

      for rawLine in content.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("YANDEX_MAPKIT_API_KEY=") {
          return String(line.dropFirst("YANDEX_MAPKIT_API_KEY=".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
    }

    return nil
  }
}
