# Portside for Android

A native Kotlin / Jetpack Compose client for **port forwarding**, using the same
Rust server as the Mac app. Requires **Android 16 (API 36) or later**, and targets
Android 17 (API 37). Tailscale must be
connected on the phone and work server. Portside uses the existing Tailscale
connection; it does not create another Android VPN.

## Build and install

Install Android Studio, Android SDK Platform 37, Build Tools 36.0.0, and a JDK
supported by Gradle 9.6 (the bundled Android Studio JDK works). Open this
`android/` directory in Android Studio, or run:

```sh
cd android
bash scripts/build.sh
```

The script uses Android Studio's bundled JDK and the standard macOS Android SDK
location when those environment variables are unset. On other setups, set
`JAVA_HOME` and `ANDROID_HOME`. Gradle and dependencies have pinned versions;
the Gradle Wrapper verifies its distribution checksum.

The debug APK is `app/build/outputs/apk/debug/app-debug.apk`. Install it on a
connected phone or emulator:

```sh
"$ANDROID_HOME/platform-tools/adb" install -r app/build/outputs/apk/debug/app-debug.apk
```

This is a locally signed development build. Play Store publishing and release
signing are not configured.

## Use it

1. Keep the existing Portside Rust server running. No server upgrade is needed.
2. Tap **Add server**. Enter its Tailscale IP or MagicDNS name, server port
   (`9417` by default), and the 64-character token from its token file.
3. On Android 17+, allow local network / nearby device access when connecting. Allow
   notifications when starting a forward so its controls appear outside the app.
4. Tap **New forward**. For example, choose local `3000` and remote `5173`.
5. Tap **Start**, then the browser icon. Your phone opens
   `http://127.0.0.1:3000`, connected to port `5173` on the work server's loopback.

`localhost` here belongs to **the phone**. Each forward starts and stops
independently. Use the server picker to switch servers; running forwards on
other servers keep working. The notification shows the total number of running
forwards and provides **Stop all**. The server and forward menus support editing
and removal, with confirmation before removal. Saving edits stops the affected
forwards; tap Start to use the updated settings.

**Ready** reports the last successful server check. **Listening** means the
phone's local listener is running. A refused remote target or a broken tunnel
closes that individual TCP connection and displays an error; the listener stays
available for the next connection. Existing TCP connections cannot resume after
a network interruption.

The foreground service keeps forwards available while you use a browser or
another app. Android can still suspend or stop work under power restrictions,
force-stop, or reboot. Settings persist, but forwards start only when requested;
the app does not restart them automatically at boot or after process death.

## Credentials and transport

Profiles and rules are stored in private app preferences. Tokens are separately
encrypted using AES-GCM with a non-exportable Android Keystore key, with the
server ID as authenticated data. Settings and tokens are excluded from backup
and device transfer. The token editor never displays an existing token; leave
it blank when editing to retain it. Reinstalling/clearing app storage removes the
configuration and requires entering tokens again.

The server uses HTTP/WebSocket inside the encrypted Tailscale network. The
client permits only tailnet or loopback IPs, short MagicDNS names, and `.ts.net`
names. DNS results must also resolve entirely to tailnet or loopback addresses.
HTTP redirects and proxies are disabled so credentials remain on that route.
If MagicDNS does not resolve on the phone, use the server's Tailscale IP.

Local listeners bind only to `127.0.0.1`; other devices cannot use the phone as
a forwarding gateway. One authenticated WebSocket carries each TCP connection,
including raw HTTP, TLS and WebSocket/HMR traffic. Both TCP half-closes are
preserved. Buffers and concurrency are bounded (16 forwards, 32 connections).
See the [shared protocol](../server/docs/protocol.md).

## Verification

Run JVM protocol and integration tests against a disposable native Rust server:

```sh
bash scripts/test.sh
```

The tests cover address/port/token/frame validation, 3 MiB binary traffic, both
half-close directions, authentication and target errors, independent stop, port
conflicts, and loopback-only binding. Plain `./gradlew :core:test` skips Rust
integration cases unless `PORTSIDE_TEST_SERVER` points to a native server binary.

Run Android Keystore and foreground-service integration tests on an Android 17
emulator:

```sh
bash scripts/test-emulator.sh
```

This starts a disposable Rust server and HTTP target on the host, uses a temporary
`adb reverse` mapping, and verifies actual HTTP forwarding with the activity in
the background. It also verifies that stopping one listener leaves another
working. The mapping, processes, and test profiles are removed afterward. The
script chooses the single connected emulator; set `ANDROID_SERIAL` explicitly
to select another test device. It installs the debug app and its test APK.
