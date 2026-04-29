# SomonLogistics

Flutter app for Somon Logistics (`com.somonlogistics.app`).

## Run

```bash
flutter pub get
flutter run
```

Place Firebase config files locally (`GoogleService-Info.plist` under `ios/Runner/`, `google-services.json` under `android/app/`); they are not committed.

**iOS / TestFlight:** `GoogleService-Info.plist` must be part of the **Runner** target (Copy Bundle Resources). If it sits only on disk but not in Xcode, release builds can crash at launch when `FirebaseApp.configure()` runs. CI (e.g. Codemagic) should write this file into `ios/Runner/` before `flutter build ipa`.
