# Portside for Android

A native Kotlin / Jetpack Compose port-forwarding client. Requires Android 16
(API 36) or later, targets Android 17 (API 37), and uses the same Rust server as
the Mac app. It uses the phone's existing Tailscale VPN; it creates no second VPN.

## Build and install

Install Android Studio, SDK Platform 37, Build Tools 36.0.0 and a JDK supported by
Gradle 9.6. Open `android/` in Android Studio, or run:

```sh
cd android
bash scripts/build.sh
"$ANDROID_HOME/platform-tools/adb" install -r app/build/outputs/apk/debug/app-debug.apk
```

The APK is `app/build/outputs/apk/debug/app-debug.apk`. On macOS, scripts use
Android Studio's bundled JDK and the usual SDK directory when environment
variables are unset. Otherwise set `JAVA_HOME` and `ANDROID_HOME` to valid local
installations. This is a locally signed development build; release signing and
Play Store publishing are not configured. Dependency versions and the Gradle
distribution checksum are pinned.

## Connect and forward

1. Keep Tailscale connected on the phone and work machine under the same account.
2. Run the Tailscale-authenticated Portside server (0.3+) on the work machine,
   or use **Host this Mac** in the updated Mac app.
3. Tap **Add server** and enter its name, Tailscale IP or MagicDNS host, and server
   port (`9417`). **There is no token or password field.** The server verifies
   this phone's Tailscale identity and authorizes devices owned by its user.
4. On Android 17+, allow local network / nearby device access when connecting.
   Allow notifications when starting a forward so its controls stay visible.
5. Tap **New forward**, choosing local `3000` and remote `5173`, for example.
6. Tap **Start** and then the browser icon to open `http://127.0.0.1:3000`.

Localhost belongs to **the phone**; the example reaches port 5173 on the work
machine. Start and stop rules independently. Switching selected servers leaves
running forwards intact. The notification shows all active forwards and has a
**Stop all** action. Editing stops affected forwards; removal asks for confirmation.

**Ready** means the most recent server check succeeded. **Listening** means the
phone's local listener is available. Remote target failures close that TCP
connection and leave the listener ready for new ones. Lost TCP connections cannot
resume after a network interruption.

A foreground service keeps forwarding while the browser or another app is open.
Android can still suspend or stop work under power restrictions, force-stop or
reboot. Profiles persist, but forwards start only on request. No boot-time restart
or claim of uninterrupted background operation is made.

## Identity and transport

Only untagged devices owned by the server's Tailscale user are accepted. The
server performs WhoIs against the actual peer address and denies other users or
unavailable identity lookup. There is no legacy authentication mode. No shared
Portside secret, Android Keystore credential or extra Tailscale login is used.

Profiles and rules live in private app preferences, excluded from backup and
device transfer. Saving settings replaces unused credential values from earlier
builds without reading or decrypting them. Tailscale supplies encryption for
HTTP/WebSocket traffic. Client DNS results must all be tailnet or loopback IPs;
HTTP redirects and proxies are disabled. If MagicDNS does not resolve, use the
server's Tailscale IP. Keep Portside included in Tailscale's VPN app selection.

Listeners bind only to `127.0.0.1`. One WebSocket carries each TCP connection,
including HTTP, HTTPS and HMR bytes, with both half-closes preserved. Buffers and
concurrency are bounded (16 forwards, 32 connections). See the
[protocol](../server/docs/protocol.md). File uploads are implemented by the Mac
client; this Android app focuses on port forwarding.

## Tests

```sh
bash scripts/test.sh
bash scripts/test-emulator.sh
```

The JVM tests run against a disposable Rust server with an isolated Tailscale CLI
fixture. They cover address/port/frame validation, 3 MiB binary transfer, both
half-close directions, identity and target failures, port conflicts, loopback-only
binding and independent stop. Plain `./gradlew :core:test` needs both
`PORTSIDE_TEST_SERVER` and `PORTSIDE_TEST_TAILSCALE` for integration cases.

Emulator tests verify private profile persistence without credentials, actual
foreground-service forwarding with the activity in the background, and stopping
one forward while another remains usable. A disposable host Rust server and HTTP
target are connected by a temporary `adb reverse` mapping; test profiles, mapping
and processes are cleaned up afterward. The script selects the single connected
emulator unless `ANDROID_SERIAL` is explicitly set. Use an Android 17 test emulator.
