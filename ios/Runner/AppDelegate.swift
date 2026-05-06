import Flutter
import UIKit
import FirebaseCore
import AppTrackingTransparency

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
    GeneratedPluginRegistrant.register(with: self)

    if #available(iOS 14, *) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        ATTrackingManager.requestTrackingAuthorization { _ in }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
