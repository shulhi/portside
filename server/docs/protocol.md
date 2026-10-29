# Portside TCP protocol v1

This is the contract for the Rust server and future native Swift client.

## Connection model

A **forward** is a local listener owned by the client, for example
`127.0.0.1:3000 → work-server loopback:5173`.

A **tunnel** carries one accepted TCP connection from that listener. Open one
WebSocket per accepted TCP connection. Do not share a tunnel between browser
connections or treat WebSocket message boundaries as TCP packet boundaries.

No create/delete-forward API or persistent control channel is needed on the
server. It accepts target ports independently on each tunnel request. Forward
labels, local port selection, saved rules, reconnect status and listener
lifecycle belong to the Swift client. This allows dynamic changes without
affecting existing tunnels.

## Discovery

Request `GET http://<server>:9417/v1/info` with the bearer header. Example:

```json
{
  "name": "portside-server",
  "version": "0.1.0",
  "protocol": "portside.tcp.v1",
  "allowed_ports": ["1024-65535"],
  "excluded_ports": [9417],
  "max_tunnels": 128,
  "active_tunnels": 0,
  "max_data_size": 65536,
  "loopback_families": ["ipv4", "ipv6"]
}
```

`active_tunnels` includes target-connect and upgrade reservations. It is a
snapshot, not a promise that a new tunnel will be admitted. `allowed_ports`
contains individual decimal ports or inclusive decimal ranges. An excluded port
always overrides an allowed range.

`GET /healthz` returns `{"status":"ok"}` and also requires authentication.
There is no listening-process/port-discovery endpoint in v1.

## WebSocket handshake

```http
GET /v1/tunnels/5173?family=ipv4 HTTP/1.1
Host: work-server:9417
Authorization: Bearer <64-character-token>
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <generated-by-WebSocket-library>
Sec-WebSocket-Version: 13
Sec-WebSocket-Protocol: portside.tcp.v1
```

`family` defaults to `ipv4` (`127.0.0.1`). Use `ipv6` for `[::1]`. Unknown query
parameters and other family values are rejected. Both are literal loopback
destinations; DNS is never used to resolve a target.

The server checks authentication, port policy and capacity, then connects to the
target with a three-second timeout **before** accepting the upgrade. Successful
upgrades respond with `Sec-WebSocket-Protocol: portside.tcp.v1`. A failed local
TCP connection therefore produces an HTTP error instead of an apparently
successful tunnel.

Use a native WebSocket client, such as Foundation's `URLSessionWebSocketTask`.
Set the bearer and subprotocol headers on its URLRequest, verify the negotiated
protocol in the session delegate, and configure network/transport permissions
for the private server address as needed. Requests containing an `Origin`
header are rejected. Tokens must not appear in URLs, query parameters or logs.
The future macOS client should store the token in Keychain.

## Binary application messages

Every WebSocket application message is binary. Byte zero is a tag:

| Tag | Remaining bytes | Meaning |
| --- | --- | --- |
| `0x00` | 0-65536 bytes | TCP data |
| `0x01` | None | EOF for this sender's TCP direction |

For example, `00 48 65 6c 6c 6f` carries the TCP bytes `Hello`. `01` carries no
TCP bytes and closes only the sender's write direction.

The maximum **application message** size is 65537 bytes including its tag. Clients
must split larger TCP reads into multiple data messages. The server currently
sends chunks of up to 16 KiB of TCP data; clients must accept any size up to the
advertised maximum. Fragmented WebSocket messages are permitted within the
message/frame limits; applications should use their WebSocket library's
assembled binary messages.

An empty WebSocket message, unknown tag, text message, EOF with extra bytes,
duplicate EOF, or data following EOF is invalid. Empty *data* (`00`) is valid.

Neither side may reinterpret data bytes as HTTP or other application messages.
Forward HTTP upgrades, TLS records and arbitrary TCP payloads as bytes.

## EOF and close

When the local browser socket reaches read EOF, send `01`. The Rust server calls
TCP write shutdown on the target, and keeps forwarding the target's response.
When the target reaches read EOF, the server sends `01`. The Swift client must
shut down the local socket's write direction and may continue reading local
bytes until its own read EOF.

When both EOFs have occurred, the server closes the WebSocket with code `1000`.
Do not close the entire WebSocket merely because one direction has ended. An
explicit disconnect/stop-now action may instead close the whole WebSocket to
terminate that TCP connection immediately.

Typical exchanges:

```text
client → server: 00 <request bytes>
client → server: 01                  (client finished writing)
server → client: 00 <response bytes> (still delivered after client EOF)
server → client: 01
server → client: WebSocket close 1000
```

## Heartbeats, backpressure and shutdown

While reading the target, the server sends WebSocket ping control frames every
25 seconds. The client WebSocket library must answer with pong control frames,
including while no local application data is being sent. The server closes a
tunnel if it receives no WebSocket message/control frame for 90 seconds while
waiting for incoming frames. After target EOF, server pings stop; the client
should complete its remaining direction or close the tunnel within that period.

Both directions are relayed concurrently with bounded buffers. The client must
also apply backpressure: await sends and local writes; avoid an unbounded queue
of socket reads or WebSocket receives. Cancellation interrupts both directions,
even when one is blocked on network I/O.

During server shutdown, new requests are refused, active tunnels receive close
code `1001`, and target TCP connections are dropped. The close write has a
one-second deadline; the server waits up to five seconds for upgraded tunnel
tasks to finish after HTTP shutdown.

## Errors

Server-generated API errors use this JSON shape before upgrade:

```json
{"error":{"code":"target_unavailable","message":"cannot connect to target loopback port"}}
```

| HTTP | Code | Meaning |
| --- | --- | --- |
| 400 | `protocol_required` | Missing/unsupported WebSocket subprotocol |
| 401 | `unauthorized` | Missing or invalid bearer token |
| 403 | `browser_origin` | Origin header supplied |
| 403 | `port_denied` | Port outside policy, zero, or server's own port |
| 404 | `not_found` | Unknown endpoint |
| 502 | `target_unavailable` | Target connection failed/refused |
| 503 | `capacity_exceeded` | Too many active/pending tunnels |
| 503 | `shutting_down` | Shutdown in progress |
| 504 | `target_timeout` | Target connect exceeded three seconds |

Malformed path/query parameters, invalid WebSocket upgrade headers and unsupported
HTTP methods can instead produce framework HTTP error responses with a text
body. Clients must handle the status even when the body is not the JSON shape.
If multiple parts of a request are invalid, do not depend on validation order.

After upgrade, the server closes with:

| Code | Meaning |
| --- | --- |
| 1000 | Both TCP directions finished normally |
| 1001 | Server shutdown or receive heartbeat timeout |
| 1002 | Invalid Portside application frame |
| 1011 | TCP/WebSocket I/O failure, including rejected oversized messages |

Network failure can end a connection without a close frame. A failed tunnel
affects its TCP connection only. It must not restart other local forwards.
Existing connections cannot be resumed after network loss; clients may keep
their local listeners and create fresh tunnels for subsequent connections.

## Transport boundary

Use `ws://<tailscale-ip-or-MagicDNS-name>:9417/...` over the existing tailnet.
Tailscale encrypts the network hop; this server has no separate TLS listener.
Do not route this token-authenticated HTTP listener over an unencrypted external
network. Tailscale access policy controls access to server port `9417`, not the
individual loopback targets inside tunnels; the server's `allowed_ports` policy
controls those targets. Bearer-token rotation currently requires a server restart.
