# Portside server

Bring web apps running on a work server to your Mac's localhost over Tailscale.

Portside has two parts: this Rust server on your work machine and a
[native SwiftUI client](../client/README.md) on your Mac. The client creates
local forwarding listeners and manages saved servers and port forwards.

```text
Mac browser → Mac localhost:3000 → Swift client
                                      │
                                Tailscale / WebSocket
                                      │
                           Rust server :9417
                                      │
                           server localhost:3000
```

The Rust server uses one authenticated listener. Each local TCP connection will
be carried by a separate WebSocket tunnel to the requested remote loopback port.
Adding or removing a local forward will not restart the server or interrupt
other tunnels. No SSH connection or per-app Tailscale Serve configuration is
needed.

## Build

Install Rust 1.93 or later. All commands below run from the `server/` directory:

```sh
cargo build --release --locked
```

The binary is `target/release/portside-server`. Build it on the work server or
for the work server's operating system and CPU architecture. The server source
supports macOS and Linux; the test suite has been run on macOS.

## Run on your work server

Create a token once:

```sh
./target/release/portside-server generate-token --output ./portside.token
```

This generates 32 cryptographically random bytes as a 64-character hex token,
creates a file with permissions `0600` on macOS/Linux, and refuses to overwrite
an existing file. The token value is never printed or logged. Keep it outside
version control and transfer it securely to the client using its Add server
dialog. Each authenticated client can access the allowed loopback ports.

With Tailscale running on the work server:

```sh
./target/release/portside-server serve \
  --listen "$(tailscale ip -4):9417" \
  --token-file ./portside.token
```

Allow your MBP to reach the work server on TCP port `9417` in your Tailscale
grants/ACLs and host firewall. The token is required in addition to network
access. Binding to a Tailscale IP requires that IP to exist on the work server.

For local development, omit `--listen`; the default is `127.0.0.1:9417`:

```sh
./target/release/portside-server serve --token-file ./portside.token
```

To limit which app ports clients can access:

```sh
./target/release/portside-server serve \
  --listen "$(tailscale ip -4):9417" \
  --token-file ./portside.token \
  --allowed-ports 3000,5173,8000-8100 \
  --max-tunnels 128
```

By default, ports `1024-65535` are allowed, except the server's own listening
port. Explicitly include lower ports if needed. The limit counts individual
active/pending TCP tunnels, not the number of selected app ports. Startup
configuration changes require a restart; clients can choose any allowed target
port at runtime without a restart.

Ctrl+C or SIGTERM closes the listener and active tunnels. Set `RUST_LOG=debug`
to log tunnel lifecycle events. Traffic contents and credentials are not logged.

## API and Swift integration

All endpoints require `Authorization: Bearer <token>`:

| Endpoint | Purpose |
| --- | --- |
| `GET /healthz` | Authenticated health check |
| `GET /v1/info` | Protocol version, port policy, limits, and current connection count |
| `GET /v1/tunnels/{port}` | Upgrade to a tunnel to `127.0.0.1:{port}` |
| `GET /v1/tunnels/{port}?family=ipv6` | Upgrade to a tunnel to `[::1]:{port}` |

The WebSocket handshake must request subprotocol `portside.tcp.v1`. Application
messages are binary, with a one-byte tag before TCP data; **plain WebSocket
payloads are not the wire protocol**. See [the full protocol](docs/protocol.md)
for framing, EOF, error handling, and the Swift client contract.

The Swift client owns each local listening port and opens a new tunnel for
every accepted local TCP connection. To stop a forward it stops that local
listener; it can either drain its established connections or close their
WebSockets. Other forwards continue independently. A control connection is not
required to keep forwards alive.

## Transport and scope

- Targets are restricted to IPv4 or IPv6 loopback. Clients cannot supply arbitrary
  hostnames, LAN targets, or external IP addresses.
- Wildcard, LAN, and public listen addresses are refused. Accepted address ranges
  are loopback and Tailscale's documented IPv4/IPv6 ranges. Address validation is
  not Tailscale identity verification; access still depends on network policy
  and the bearer token. See [Tailscale address ranges](https://tailscale.com/docs/reference/reserved-ip-addresses).
- The server speaks HTTP/WebSocket, with encryption supplied by Tailscale between
  machines. It does not implement TLS, join the tailnet itself, invoke Tailscale
  Serve, or change any Tailscale/Rex configuration.
- TCP carries HTTP, HTTPS and application WebSockets unchanged. Dev framework
  host/origin rules, hard-coded callback URLs, and HMR port settings still apply.
- TCP half-closes, bounded buffering, connection limits, connect timeouts,
  heartbeats, and graceful shutdown are implemented.
- UDP, automatic port discovery, and service installation are not implemented.
- The client can start saved forwarding rules on launch when opted in. Broken
  TCP connections cannot be resumed after sleep or network loss; the browser/app
  must reconnect.

## Verify

```sh
cargo fmt --all -- --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

Tests use real ephemeral loopback listeners and WebSockets. They cover
authentication, policy enforcement, independent dynamic tunnels, binary traffic,
both half-close directions, capacity release, IPv6, and shutdown.
