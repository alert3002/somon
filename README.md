# SomonLogistics

Flutter app for Somon Logistics (`com.somonlogistics.app`).

## Run

```bash
flutter pub get
flutter run
```

Place Firebase config files locally (`GoogleService-Info.plist` under `ios/Runner/`, `google-services.json` under `android/app/`); they are not committed.

**iOS / TestFlight:** `GoogleService-Info.plist` is in the **Runner** target (Copy Bundle Resources). The repo contains a **placeholder** plist so Codemagic/Xcode archive always finds the file; for real Firebase/FCM, download the plist from the Firebase console and either replace `ios/Runner/GoogleService-Info.plist` locally (do not commit secrets) or set **`GOOGLE_SERVICES_INFO_PLIST_BASE64`** in Codemagic (base64 of the real file) — see `codemagic.yaml`.
