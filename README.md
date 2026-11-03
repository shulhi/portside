# Portside

Bring web apps running on a work server to your Mac or Android phone's localhost
over Tailscale.

```text
portside/
├── server/    Rust forwarding server, tests, and protocol documentation
├── client/    Native SwiftUI Mac application and forwarding engine
└── android/   Native Kotlin / Jetpack Compose Android application
```

The server is a standalone Cargo project. Run its build, test, and startup
commands from `server/`:

```sh
cd server
cargo build --release --locked
cargo test --locked
```

See the [server setup instructions](server/README.md) and
[client/server protocol](server/docs/protocol.md).

Build and launch the native macOS client:

```sh
cd client
bash scripts/build-app.sh
open dist/Portside.app
```

See the [client guide](client/README.md) for setup, Tailscale identity authorization, and
end-to-end testing. Server and client have independent build systems.
The Mac app also bundles the Rust server: choose **Host this Mac** to access
apps running on that Mac from your Android phone or another computer.

Build the Android client (Android 16 or later):

```sh
cd android
bash scripts/build.sh
```

See the [Android guide](android/README.md) for installing the APK, connecting
through Tailscale, and testing foreground port forwarding. Both clients use the
same Tailscale-authenticated Rust server. Only devices on the server owner’s
Tailscale account are allowed, and no Portside secret is needed.
