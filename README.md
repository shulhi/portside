# Portside

Bring web apps running on a work server to your Mac's localhost over Tailscale.

```text
portside/
├── server/    Rust forwarding server, tests, and protocol documentation
└── client/    Native SwiftUI application and forwarding engine
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

See the [client guide](client/README.md) for setup, Keychain storage, and
end-to-end testing. Server and client have independent build systems.
