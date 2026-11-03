# Portside for Mac

A native SwiftUI client and managed Rust server for accessing your apps through
Tailscale. Requires macOS 27+, Xcode 27+ and Rust 1.93+ to build. There are no
third-party Swift dependencies.

## Build and open

From `client/`:

```sh
bash scripts/build-app.sh
open dist/Portside.app
```

The script builds optimized Swift and Rust executables, bundles the server in
`Contents/Helpers`, generates the icon, and signs the helper and app locally.
It uses the installed Xcode toolchain without changing `xcode-select`. Relaunch
the app when ready; packaging does not overwrite a running executable.
Release signing and notarization are not configured.

The main window opens at 860 × 520 points, with a native, collapsible server
sidebar, a compact forward list, and a detail pane. Columns resize independently.
Select a forward to see its route, connection count, received bytes, and settings.
Use its play/stop control in the list, or the Start/Stop button in **Overview**.
Toolbar actions add forwards, open localhost in a browser, and edit or remove items.
Blue is the single accent, with system selection colors and light/dark appearance.

## Tailscale identity

Portside uses your existing Tailscale connection. The server verifies every
request through Tailscale WhoIs and accepts only untagged devices belonging to
the server's Tailscale account. No token, password, extra login, or Keychain
access is required. Use the Tailscale-authenticated server version (0.3+);
there is no token fallback. Tailscale must be installed and connected on both
machines, and its network policy must permit the server port.

## Connect to a work server

1. Run the [Rust server](../server/README.md) on the work machine.
2. Choose **Add server**. Enter a name, Tailscale IP or MagicDNS host, and its
   server port (`9417` by default).
3. Use **Check** to verify identity and protocol compatibility.
4. Choose **New forward (⌘N)** and enter its local and remote app ports.
5. Save and start it, then use its browser button to open localhost on this Mac.

Forwards start and stop independently. Stopping closes that rule's listener and
connections. Saving server edits stops its forwards and queued file transfers.
Removing a server also removes its rules, with confirmation. **Listening** means
the local listener is available; individual target failures leave it ready for
new connections. The displayed connection count is the number of active TCP
connections, not the number of forwarded apps. **Ready** is the most recent
server check, not a continuous availability monitor.

The red traffic light closes the window while forwards continue. Click the Dock
icon or **Window → Show Portside (⌘0)** to reopen it. Enable **Settings → General →
Run in menu bar** to hide the Dock icon and keep Portside in the menu bar instead.
The preference persists across launches. Its menu can start or stop individual
forwards, add a forward, open the window, and open Settings. **Show Dock Icon**
turns menu-bar mode off and reopens the window. **Quit Portside** in that menu,
or **Quit (⌘Q)** in the window, stops forwards, transfers and hosting.
Rules with **Start when Portside opens** enabled start on
launch; broken TCP connections do not resume after sleep or network loss.

## Host apps running on this Mac

Choose **Host this Mac** in the sidebar, **Server → Host This Mac…**, or
**Settings (⌘,) → Hosting**:

1. Connect Tailscale and click **Detect** to select this Mac's Tailscale IP.
2. Choose a server port (`9417`) and the app ports to share. The default is
   `3000,5173,8080`; comma-separated ports and ranges such as `8000-9000` work.
3. Click **Start server**. Portside discovers this Mac's Tailscale owner, starts
   the bundled Rust helper, and verifies authenticated readiness.
4. On the phone or another Mac, add this Mac's IP and server port. That device
   must use the same Tailscale account. No shared secret is needed.
5. Start a forward there, using the Mac app's port as the remote port.

Hosting and outgoing forwards work independently. **Stop server** closes incoming
connections without stopping outgoing forwards. Closing windows keeps hosting
active; quitting or crashing closes the supervisor pipe and stops the helper.
Keep this Mac awake. Hosting does not automatically resume at launch or reboot.
To receive images/files on this Mac, stop hosting, enable **Allow file uploads**
in Hosting settings, choose an **Upload folder** (default `~/PortsideUploads`),
and start the server again. The selected folder persists, and the Rust helper
receives `--upload-dir`. Rexlink can then upload images to this Mac and paste
returned paths into local Codex/Claude sessions. Existing configurations keep
uploads disabled until you enable them.

The installed Tailscale CLI is detected at the usual macOS locations and used
as the LocalAPI identity client. An unavailable CLI, disconnected Tailscale,
tagged server identity or occupied listening port produces a startup error.
Settings and the latest startup log are stored privately under
`~/Library/Application Support/Portside/Host/`. No server token is created or read.
Loopback binds are reserved for isolated identity-fixture tests; use the actual
Tailscale IP for normal hosting.

## Send files and clipboard images

The selected server has a drop area at the bottom of **Overview**. **Files** shows
the same drop area and a list of this session's transfers. Drop regular files, click
**Paste**, or focus it and press **⌘V**. **Transfer → Paste Image or Files (⌘⇧V)**
works throughout the app. The **+** button opens a file picker. Clipboard data is
read only on explicit paste, not monitored. Folders must be zipped first.

The server needs `--upload-dir`. The Ubuntu service defaults to
`~/PortsideUploads`. Use the folder control to select a relative subfolder;
queued files retain their original destination. Transfers show progress and
cancellation, and **Copy path** copies the absolute uploaded file path for a
remote agent chat. History lasts for this app session. Copying a path does not
itself attach an image; ask the remote agent to read the file.

Files stream from disk. Clipboard PNGs retain their bytes; other supported
images convert to PNG. The server enforces its advertised size limit, generates
unique filenames and prevents folder traversal. Canceling an already completed
request can leave its file on the server. Uploaded files remain user-managed.

## Settings and verification

Profiles and rules are saved atomically at
`~/Library/Application Support/Portside/configuration.json`. No app credentials
are stored. Local forwarding listeners bind only to `127.0.0.1`.

```sh
bash scripts/test.sh
```

This builds a native disposable Rust server and supplies a test-only Tailscale
identity fixture. Tests cover identity authorization and failure, dynamic
forwards, binary traffic, both half-closes, port collisions, server supervision,
file/image uploads and configuration. Named pasteboards keep the user clipboard
untouched. Real Tailscale identity is also checked separately during deployment.
Never use the test identity fixture for production hosting.

App tests cover persisted menu-bar preferences and duplicate scene-binding writes.
After changing scenes or lifecycle code, also launch the packaged release app:
unit tests and standalone view previews do not exercise the full scene graph.
