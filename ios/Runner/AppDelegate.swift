import Flutter
import UIKit
import FirebaseCore
import AppTrackingTransparency

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// Запрашиваем ATT один раз, когда приложение уже активно (требование Apple для iPad/iOS 18+).
  private var attPromptScheduled = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    scheduleAppTrackingRequest()
  }

  private func scheduleAppTrackingRequest() {
    guard !attPromptScheduled else { return }
    guard #available(iOS 14, *) else { return }

    attPromptScheduled = true

    // Диалог показывается только если статус «не определён» и в системе включено
    // «Разрешить приложениям запрашивать отслеживание».
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
      ATTrackingManager.requestTrackingAuthorization { _ in }
    }
  }
}
