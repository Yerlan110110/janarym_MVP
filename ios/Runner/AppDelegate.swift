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
      Bundle.main.path(forResource: ".env.example", ofType: nil, inDirectory: "flutter_assets"),
      Bundle.main.path(
        forResource: ".env",
        ofType: nil,
        inDirectory: "Frameworks/App.framework/flutter_assets"
      ),
      Bundle.main.path(
        forResource: ".env.example",
        ofType: nil,
        inDirectory: "Frameworks/App.framework/flutter_assets"
      )
    ]

    for path in paths {
      guard let filePath = path else { continue }
      guard let content = try? String(contentsOfFile: filePath) else { continue }

      for rawLine in content.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = parseEnvValue(line, key: "YANDEX_MAPKIT_API_KEY") {
          return value
        }
      }
    }

    return nil
  }

  private func parseEnvValue(_ line: String, key: String) -> String? {
    let prefix = "\(key)="
    guard line.hasPrefix(prefix) else { return nil }
    let rawValue = String(line.dropFirst(prefix.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let uncommented = rawValue.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
      .first
      .map(String.init) ?? rawValue
    return uncommented
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
