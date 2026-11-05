# Paste clipboard images in Rex

Press **⌘⇧V** in Rex on your Mac to paste the path of a clipboard image into
the focused terminal. For a remote pane, Portside uploads the image first and
Rex pastes the server's returned path. For a local pane, the image is saved in
`~/Library/Caches/Portside/RexImages`. The shortcut inserts the path without
pressing Return. Screenshots and single image files copied in Finder work;
images are saved as PNGs with a maximum edge of 2,000 pixels. Use **⌘V** for text.
If a remote upload takes more than a moment, a small Mac panel shows its
progress without taking focus away from Rex. The panel closes when the upload
finishes; the image path is then pasted into the original pane.

Build Portside with `bash client/scripts/build-app.sh` from the repository root.
The build includes `portside-paste` in `Portside.app/Contents/Helpers`. Enable
file uploads on each remote Portside server you want to use, and connect both
machines to Tailscale.

Add this to your Mac's Rex `init.lua`, replacing the checkout path and host
mapping with your own:

```lua
local checkout = "/absolute/path/to/portside"
dofile(checkout .. "/integrations/rex/image-paste.lua").setup {
  helper = checkout .. "/client/dist/Portside.app/Contents/Helpers/portside-paste",
  rex_cli = "/absolute/path/to/rex", -- use the output of command -v rex
  hosts = {
    ["work-laptop"] = {host = "100.64.1.2", port = 9417, folder = "rex-images"},
  },
}
rex.bind("cmd+shift+v", "portside_image_paste")
```

Run `rex hosts` for the labels to use as keys in `hosts`. Each destination
must be a numeric Tailscale address on the same machine as its Rex host. The
optional `folder` is relative to that server's upload directory. A remote
pane with no mapping will not receive an image. The action only reads the
clipboard for clients connected to the Mac's local Rex socket.
For a remote pane, the action checks the requesting client on that local socket
before uploading. If you use a custom local Rex socket, set `local_socket` to
its absolute filesystem path.

Run `rex config check` and `rex config reload` to activate the binding.

The focused-pane shortcut was inspired by
[rex-image-paste](https://github.com/pablasso/rex-image-paste). This integration
uses Portside's existing Tailscale-authenticated file upload API.
