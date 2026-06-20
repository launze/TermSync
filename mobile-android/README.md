# TTY1 Mobile (Android)

Android client for TTY1 cross-platform terminal emulator.

## Prerequisites

- Android Studio Hedgehog+
- Android SDK 34
- Kotlin 1.9.20
- JDK 17

## Setup

1. Open project in Android Studio
2. Sync Gradle files
3. Run on emulator or device

## Build

```bash
# Debug build
./gradlew assembleDebug

# Release build
./gradlew assembleRelease

# Install on device
./gradlew installDebug
```

Debug builds use package `com.termsync.mobile.debug`; release builds use
`com.termsync.mobile`. They install side by side, so manual APK installs and
in-app update checks will not cross-upgrade between debug and release.

Release upgrades require every APK to be signed with the same release keystore.

## Features

- View all active terminals from paired desktop
- Tab-based interface (one tab per split terminal)
- Real-time terminal output
- Terminal input with special keys
- WSS connection with self-signed certificate trust

## Certificate

The server's self-signed certificate is embedded in:
`app/src/main/res/raw/server_cert.crt`

To update the certificate:
1. Generate new cert on server: `make certs`
2. Copy to `app/src/main/res/raw/server_cert.crt`
3. Rebuild the app
