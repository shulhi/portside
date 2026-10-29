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

## Build for x86_64 Ubuntu from a Mac

The repository includes a cross-build script using
[cargo-zigbuild](https://github.com/rust-cross/cargo-zigbuild). It targets
`x86_64-unknown-linux-gnu` with minimum glibc version `2.31`. This creates a
Linux executable for Intel/AMD 64-bit servers from an Apple Silicon or Intel
Mac. The native macOS build above does not produce a Linux executable.

From `server/`, set up the tools and build once:

```sh
bash scripts/build-linux-x86_64.sh --setup
```

This installs pinned versions of cargo-zigbuild and Zig into the ignored
`server/.cross-tools/` directory and adds the Linux standard library to your
active Rust toolchain using rustup. It requires Rust/rustup, Python 3, internet
access, and either uv or Python's venv/pip support. Tool caches stay under
`server/target/`.

Subsequent builds:

```sh
bash scripts/build-linux-x86_64.sh
```

The result is `server/target/x86_64-unknown-linux-gnu/release/portside-server`
relative to the repository root. Transfer that executable to your Ubuntu
server using your usual file-transfer method, then run `chmod +x` and
`./portside-server --help` there. `uname -m` on the Ubuntu machine should report
`x86_64`; `ldd --version` shows its installed glibc version. The build targets
glibc 2.31 or newer and is dynamically linked, not a fully static binary.

The cross-build has been verified to produce an x86_64 Linux ELF executable on
macOS. It has not yet been executed on the work server.

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

## Receive files and pasted images

Enable authenticated uploads by choosing a server-side destination directory:

```sh
./target/release/portside-server serve \
  --listen "$(tailscale ip -4):9417" \
  --token-file ./portside.token \
  --upload-dir "$HOME/PortsideUploads"
```

The client can drop regular files or paste clipboard images into this directory,
optionally choosing a relative subfolder such as `project/screenshots`. Each
successful upload returns its absolute server path for pasting into a remote
agent chat. Changing `--upload-dir` changes the base directory; clients cannot
write outside it through subfolder paths or escaping symlinks.

Uploads are disabled when `--upload-dir` is omitted. Enabled uploads default to
100 MiB per file; change this with `--max-upload-bytes`. Four uploads can run
concurrently, each with a ten-minute deadline. File bodies stream to disk.
Files receive private permissions, unique names, and are published only after
the transfer completes. Interrupted requests remove temporary files. Existing
files are never overwritten. Filenames must be plain basenames up to 180 UTF-8
bytes; directories must be zipped before sending. Uploaded files remain until
you manage or delete them on the server.

## Run as an Ubuntu background service

For an always-on work machine, use the included systemd **user service**. The
server remains a foreground process supervised by systemd; it does not fork or
detach itself. Systemd starts it automatically, restarts it after failures, and
captures its logs independently of terminal or Rex sessions.

These commands run on the Ubuntu server. Put the executable at
`~/portside-server`, retain your existing private token file, and install the
unit from `deploy/portside.service` into `~/.config/systemd/user/portside.service`:

```sh
mkdir -p ~/.config/systemd/user ~/.config/portside
cp deploy/portside.service ~/.config/systemd/user/portside.service
cat > ~/.config/portside/server.env <<EOF
PORTSIDE_LISTEN=$(tailscale ip -4):9417
PORTSIDE_TOKEN_FILE=$HOME/portside-token
EOF
chmod 600 ~/.config/portside/server.env
systemd-analyze --user verify ~/.config/systemd/user/portside.service
systemctl --user daemon-reload
```

Change `PORTSIDE_TOKEN_FILE` to the absolute path of your token file if needed.
This environment file holds its path, not the token itself. The stored Tailscale
address is stable for the device; update it if the device is re-enrolled with a
different address. If Tailscale is unavailable at boot, the service retries every
five seconds until binding succeeds.

Stop any manually started Portside process before starting the service on the
same port. This one-time transition closes its existing TCP tunnels; local
Portside listeners can accept fresh browser connections afterward.

```sh
loginctl enable-linger "$USER"
systemctl --user enable --now portside.service
```

Lingering lets your user manager start at boot and keep services running after
logout. Some systems require administrator authorization for `enable-linger`;
if denied, an administrator can run `sudo loginctl enable-linger <username>`.
Portside itself runs as your normal user and does not need root access.

Manage the daemon:

```sh
systemctl --user status portside.service
journalctl --user -u portside.service -f
systemctl --user restart portside.service
systemctl --user stop portside.service
```

Restart the service after changing `server.env`. To stop it and disable automatic
startup, use `systemctl --user disable --now portside.service`. This does not
disable lingering for other user services.

The included service enables uploads to `~/PortsideUploads`. To choose a
different base directory, add an absolute path in `~/.config/portside/server.env`:

```sh
PORTSIDE_UPLOAD_DIR=/home/your-user/your-project/attachments
```

After updating from a version before 0.2, install both the new binary and the
updated unit, then run `systemctl --user daemon-reload` and restart the service.

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
