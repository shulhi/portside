# Portside server

A Rust TCP forwarding server for the native Mac and Android clients. Tailscale
supplies transport encryption and device identity. **There is no Portside token,
password, or legacy authentication mode.** Requires Rust 1.93+ to build and an
installed, connected Tailscale client to run.

## Authentication

At startup, Portside reads `tailscale status --json` and records the server
node's owner user ID. The server must be a user-owned device; tagged server
nodes are refused. For every HTTP request and WebSocket handshake, Portside:

1. Takes the peer IP and port from the accepted socket, ignoring identity and
   forwarded-address headers from the client.
2. Runs `tailscale whois --json --proto=tcp <peer-address>` through the installed
   CLI, which talks to the existing local Tailscale daemon.
3. Checks the returned device ID and matching node/profile user IDs. Only
   untagged devices owned by the server's Tailscale user are accepted.

Another user's device is rejected with HTTP 403. An unavailable, malformed, or
failed lookup returns HTTP 503. Discovery failure prevents startup. Lookups are
fresh for each request, have a deadline, and are limited to 16 concurrent CLI
processes. No app-specific secret or Tailscale cloud API key is needed.

Tailscale grants/ACLs still control reachability to Portside's listening port.
Portside's allowed-port policy separately controls which server-local apps can
be forwarded. Requests containing `Origin` are rejected, so browser pages
cannot use the forwarding API directly. Existing tunnels are authenticated at
handshake time; there is no continuous application-level identity polling.

## Build and run

From `server/`:

```sh
cargo build --release --locked
./target/release/portside-server serve \
  --listen "$(tailscale ip -4):9417" \
  --tailscale-bin "$(command -v tailscale)" \
  --allowed-ports 3000,5173,8000-8100
```

Use the installed Tailscale CLI's full path if it is not on the process's PATH.
Clients only enter the server address and port, and must connect through their
existing Tailscale connection under the same account. Loopback binds are useful
for isolated tests with an injected identity source; ordinary localhost traffic
is not treated as authenticated Tailscale traffic.

Wildcard, LAN, and public binds are refused. Targets are always IPv4 or IPv6
loopback on this server. Ports `1024-65535` are allowed by default, excluding
Portside's own listening port. Explicit policies can include lower ports.
`--max-tunnels` defaults to 128 and counts individual TCP connections. Each TCP
connection uses its own WebSocket; forwards can start and stop independently.

Ctrl+C/SIGTERM requests graceful shutdown. `RUST_LOG=debug` enables tunnel
lifecycle diagnostics; payloads and identity responses are not logged.

## Cross-build for x86_64 Ubuntu on a Mac

```sh
bash scripts/build-linux-x86_64.sh --setup  # first time
bash scripts/build-linux-x86_64.sh
```

The script uses pinned project-local cargo-zigbuild/Zig tools and builds
`target/x86_64-unknown-linux-gnu/release/portside-server` for glibc 2.31+.
Copy that binary to the Ubuntu server; a native Mac executable will not run there.

## Ubuntu user service

Put the executable at `~/portside-server`, and install
`deploy/portside.service` at `~/.config/systemd/user/portside.service`:

```sh
mkdir -p ~/.config/systemd/user ~/.config/portside
cp deploy/portside.service ~/.config/systemd/user/portside.service
cat > ~/.config/portside/server.env <<EOF
PORTSIDE_LISTEN=$(tailscale ip -4):9417
EOF
chmod 600 ~/.config/portside/server.env
systemd-analyze --user verify ~/.config/systemd/user/portside.service
systemctl --user daemon-reload
loginctl enable-linger "$USER"
systemctl --user enable --now portside.service
```

The unit invokes `/usr/bin/tailscale`, runs as your user, retries failed startups,
starts at boot with lingering enabled, and stays independent of Rex/SSH sessions.
It enables uploads to `~/PortsideUploads`; override `PORTSIDE_UPLOAD_DIR` with an
absolute path in `server.env` if needed. It must be able to query Tailscale status
and WhoIs as the service user. Never grant an unrelated identity just to make a
lookup succeed.

```sh
systemctl --user status portside
systemctl --user restart portside
systemctl --user stop portside
journalctl --user -u portside -f
```

When upgrading, replace both the binary and unit, remove the obsolete
`PORTSIDE_TOKEN_FILE` environment setting, reload systemd and restart. Old token
files are not read. Mac and Android clients must use the Tailscale-authenticated
Portside version; there is no token fallback.

## Host this Mac

The Mac app bundles the same Rust server and manages it under **Host this Mac**.
Its `--shutdown-on-stdin-eof` option stops the helper when the parent app's pipe
closes, including after a crash. The standalone systemd unit does not use this
option. See the [Mac guide](../client/README.md).

## Uploads

Enable uploads with `--upload-dir /absolute/directory`; otherwise they are
disabled. The Mac client can send files and pasted images, selecting a relative
subfolder under that root. File bodies stream to disk, default to a 100 MiB
limit (`--max-upload-bytes`), and have a ten-minute deadline. Four uploads can
run concurrently. Private, uniquely named files are published only on completion;
interrupted uploads remove temporary files and existing files are never replaced.
Path traversal and symlinks escaping the root are rejected. Clients receive the
absolute server path. The Android client currently implements port forwarding.

## Protocol and verification

`GET /healthz`, `GET /v1/info`, `GET /v1/tunnels/{port}?family=ipv4|ipv6`, and
`PUT /v1/files` all require verified Tailscale owner identity. No authorization
header is sent. `/v1/info` advertises `authentication: "tailscale-owner"`.
The tunnel subprotocol remains `portside.tcp.v1`; see [the protocol](docs/protocol.md)
for binary framing, half-closes, limits and errors.

```sh
cargo fmt --all -- --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

Tests exercise real sockets with an injected identity provider, plus the CLI
transport with a test-only fixture. They cover other-user denial, unavailable
identity, spoofed identity/forwarded headers, browser-origin rejection, dynamic
forwards, binary data, half-closes, capacity, uploads, and supervisor shutdown.
Never configure the test identity fixture as a production Tailscale executable.
