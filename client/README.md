# Portside for Mac

A native SwiftUI application for bringing apps on your work server to this
Mac's localhost through Tailscale. It can also host this Mac's apps for other
Portside clients. Requires macOS 27 or later, Xcode 27 or later, and Rust 1.93+
to build the bundled server.
There are no third-party Swift dependencies.

The interface uses native Liquid Glass buttons, menus, sheets, and window controls.
The compact forwarding table keeps its content surface for readability.

## Build and open

From the `client/` directory:

```sh
bash scripts/build-app.sh
open dist/Portside.app
```

The script builds optimized Swift and Rust executables, bundles the server in
`Contents/Helpers`, generates the app icon, packages its Info.plist, and signs
the helper and bundle locally with ad hoc identities. It uses the
installed Xcode toolchain when available, without changing `xcode-select`.
You can also open `Package.swift` in Xcode to work on the application.

This build is for local development. Distribution signing and notarization are
not configured. Keychain may ask for permission again after rebuilding an
ad-hoc-signed app; distribution builds should use a stable signing identity.

The red traffic-light button closes the window while Portside keeps forwards
and file transfers running. Click its Dock icon to show the window again, or
use **Window → Show Portside (⌘0)**. Use **Portside → Quit Portside (⌘Q)** to
quit and stop all forwards and transfers.

## Host apps running on this Mac

Choose **Host this Mac** in the sidebar, **Server → Host This Mac…**, or open
**Settings (⌘,)**. Hosting starts only when requested:

1. Keep Tailscale connected and use **Detect** to select this Mac's Tailscale IP.
2. Choose the server port (`9417` by default) and the app ports to share. The
   default is `3000,5173,8080`; comma-separated ports and ranges are supported.
3. Click **Start server**. Portside starts its bundled Rust server and checks
   authenticated readiness before showing **Hosting**.
4. On your Android phone or another Mac, add this Mac's IP and server port.
   Use **Copy token** to get its automatically generated token.
5. Add a forward in that client, using the app's port on this Mac as the remote
   port, then open the client's localhost browser URL.

Hosting and outgoing remote forwards work independently. **Stop server** closes
incoming connections without stopping your outgoing forwards. Closing the main
or Settings window keeps hosting active. Quitting Portside stops it. The helper
also watches a parent pipe, so a crash or force-quit does not leave an orphaned
server behind. Keep this Mac awake while accessing its apps remotely. Hosting
does not automatically resume after app launch, login, or reboot.

Only a literal Tailscale or loopback IP is accepted; wildcard/LAN binds are
rejected. Use `127.0.0.1` only for local testing. The app's host mode supports
port forwarding; incoming file uploads are disabled. This mode currently uses
the same bearer-token authentication as the Ubuntu server. Tailscale WhoIs
authorization has not yet replaced tokens.

Hosting settings, the private token, and the most recent startup log live in
`~/Library/Application Support/Portside/Host/`. The host directory is created
with mode `0700` and its token with mode `0600`. Starting again reuses the token.
Changes to IP, server port or allowed ports require stopping and starting the
hosted server. An occupied port produces an error and leaves its owner alone.

## Connect a work server

1. Run the [Rust server](../server/README.md) on your work machine and keep
   Tailscale connected on both machines.
2. Choose **Add server**. Enter a name, Tailscale IP or MagicDNS host, server
   port (default `9417`), and the token from the server's token file.
3. Use **Check connection** to verify authentication and protocol compatibility.
4. Choose **New forward** (⌘N). Enter a name, a local port, and the app's port
   on the work server. Select IPv6 only if the remote app listens on `::1`.
5. Save and start the forward. Use its browser button to open
   `http://localhost:<local-port>`.

Each forward can be started or stopped independently. **Stop** closes that
forward's listener and active connections. Editing a forward restarts it when
"Start after saving" is selected. Editing a server stops its forwards and file
transfers so old connections don't retain previous credentials or destinations.
Server and forward removal requires confirmation.

The green **Listening** state means the local listener is running. An individual
connection can still fail if the remote app is stopped; the card displays that
error while keeping the listener available for a later retry. **Server ready**
reports the most recent successful server check, rather than a continuous
availability monitor.

## Send files and clipboard images

The selected server has a compact drop area below its forwarding list. Drop
files there, click **Paste**, or focus the area and press **⌘V** to send a copied
image or file. **Transfer → Paste Image or Files (⌘⇧V)** also works from anywhere
in the app. The **+** button opens a file picker. Clipboard data is read only
when you request a paste; it is not monitored in the background.

The server must run version 0.2+ with `--upload-dir` configured. The included
Ubuntu service defaults to `~/PortsideUploads`. Its base directory appears in
the drop area; use the folder button to choose a relative subfolder per server.
Changing a subfolder does not restart port forwards. Files already queued keep
the destination they had when added.

Transfers run in a queue with progress and cancellation. After success, click
**Copy path** and paste the absolute server path into your remote agent chat.
The history button provides paths for recent transfers in this app session.
Copying the path does not itself attach an image; ask the agent to read the file.
Upload history is kept in memory, while destination subfolders persist with
your server profiles. Existing profiles migrate automatically.

Regular files stream from disk; clipboard images preserve PNG bytes or convert
other supported image representations to PNG. Matching filenames receive
unique server names. Folder drops are rejected; zip a directory first. Files
default to a 100 MiB limit, controlled by the server. Cancelling a transfer that
has already been acknowledged can leave its completed file on the server.

## Settings and credentials

- Server profiles and forwarding rules are saved atomically to
  `~/Library/Application Support/Portside/configuration.json`.
- Bearer tokens are stored separately in macOS Keychain, under service
  `app.portside.server-token`. They never enter the JSON configuration or logs.
- On an existing server, leave the replacement token blank to retain its token.
- "Start when Portside opens" is opt-in per rule. Other rules stay stopped after
  relaunch. Listeners remain available across a transient remote network loss;
  subsequent browser connections open fresh tunnels when connectivity returns.
  Already-broken TCP connections are not resumed.
- Browser links use HTTP. For an HTTPS app or a non-web TCP service, use its
  appropriate scheme/tool with the configured local port instead.

Only loopback IPs, Tailscale IP ranges, single-label MagicDNS names and `.ts.net`
names are accepted as server hosts. Local listeners bind to `127.0.0.1`, never
to all interfaces. The server supplies its allowed target-port policy before a
forward starts; multiple saved rules cannot claim the same local port.

## Transport

The app implements [Portside TCP protocol v1](../server/docs/protocol.md), with
one authenticated WebSocket per accepted local TCP connection. Both directions
apply backpressure and preserve independent TCP EOFs. Foundation handles
WebSocket ping/pong and verifies the negotiated subprotocol through the session
delegate. Network.framework owns the local loopback listeners and connections.

Tailscale encrypts the hop between machines. App Transport Security exceptions
are restricted to the Tailscale IP ranges, `.ts.net` domain and local networking;
there is no global arbitrary-load exception. Use only your tailnet host names;
the application does not authenticate Tailscale identity independently.

## Tests

Full Xcode is required for XCTest. Run from `client/`:

```sh
bash scripts/test.sh
```

This builds the Rust server and runs the Swift unit and integration tests.
Integration tests start temporary Rust instances on loopback, use disposable
credentials and real TCP/WebSocket connections, and leave your saved profiles
and Keychain untouched. Coverage includes independent forwards, binary transfer,
half-closes, port conflicts, failed targets, authentication, frame validation,
address policy and configuration persistence.

For unit tests without the Rust server, run `xcrun swift test` with
`PORTSIDE_TEST_SERVER` unset; the integration tests are skipped. If the active
developer directory is Command Line Tools, set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for that command.
