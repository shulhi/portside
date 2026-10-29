# Portside

Bring web apps running on a work server to your Mac's localhost over Tailscale.

```text
portside/
├── server/    Rust forwarding server, tests, and protocol documentation
└── client/    Future native Swift application
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

The native Swift client will live alongside the server in `client/`.
