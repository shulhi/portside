mod common;
use std::sync::{Arc, atomic::Ordering};
use std::{net::SocketAddr, time::Duration};

use futures_util::{SinkExt, StreamExt};
use portside_server::{
    config::{PROTOCOL, PortPolicy, ServerConfig},
    serve,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
    time::timeout,
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{
        Error, Message,
        client::IntoClientRequest,
        http::{Request, StatusCode},
    },
};
use tokio_util::sync::CancellationToken;

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

struct Server {
    addr: SocketAddr,
    identity: Arc<common::TestIdentity>,
    shutdown: CancellationToken,
    task: Option<JoinHandle<anyhow::Result<()>>>,
}

impl Server {
    async fn start(max_tunnels: usize, allowed_ports: PortPolicy) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let shutdown = CancellationToken::new();
        let identity = Arc::new(common::TestIdentity::default());
        let config = ServerConfig {
            listen: addr,
            auth: identity.auth(),
            allowed_ports,
            max_tunnels,
            upload_dir: None,
            max_upload_bytes: 100 * 1024 * 1024,
        };
        let task = tokio::spawn(serve(listener, config, shutdown.clone()));
        Self {
            addr,
            identity,
            shutdown,
            task: Some(task),
        }
    }

    fn request(&self, port: u16) -> Request<()> {
        let mut request = format!("ws://{}/v1/tunnels/{port}", self.addr)
            .into_client_request()
            .unwrap();
        request
            .headers_mut()
            .insert("Sec-WebSocket-Protocol", PROTOCOL.parse().unwrap());
        request
    }

    async fn connect(&self, port: u16) -> Socket {
        let (socket, response) = timeout(Duration::from_secs(5), connect_async(self.request(port)))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(response.headers()["Sec-WebSocket-Protocol"], PROTOCOL);
        socket
    }

    async fn get(&self, path: &str, extra_headers: &str) -> (u16, serde_json::Value) {
        let mut stream = TcpStream::connect(self.addr).await.unwrap();
        stream
            .write_all(
                format!(
                    "GET {path} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n{extra_headers}\r\n",
                    self.addr
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut bytes = Vec::new();
        timeout(Duration::from_secs(5), stream.read_to_end(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        let response = String::from_utf8(bytes).unwrap();
        let (headers, body) = response.split_once("\r\n\r\n").unwrap();
        let status = headers.split_whitespace().nth(1).unwrap().parse().unwrap();
        (status, serde_json::from_str(body).unwrap())
    }

    async fn stop(mut self) {
        self.shutdown.cancel();
        timeout(Duration::from_secs(7), self.task.take().unwrap())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.shutdown.cancel();
    }
}

async fn echo_server() -> (u16, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut buffer = vec![0; 8192];
        loop {
            let count = socket.read(&mut buffer).await.unwrap();
            if count == 0 {
                break;
            }
            if socket.write_all(&buffer[..count]).await.is_err() {
                break;
            }
        }
    });
    (port, task)
}

async fn next_binary(socket: &mut Socket) -> Vec<u8> {
    timeout(Duration::from_secs(5), async {
        loop {
            match socket.next().await.unwrap().unwrap() {
                Message::Binary(data) => return data.to_vec(),
                Message::Ping(_) => socket.flush().await.unwrap(),
                Message::Pong(_) => {}
                other => panic!("expected binary message, got {other:?}"),
            }
        }
    })
    .await
    .unwrap()
}

async fn read_close(socket: &mut Socket) -> u16 {
    timeout(Duration::from_secs(5), async {
        loop {
            match socket.next().await.unwrap().unwrap() {
                Message::Close(Some(frame)) => return frame.code.into(),
                Message::Ping(_) => socket.flush().await.unwrap(),
                _ => {}
            }
        }
    })
    .await
    .unwrap()
}

async fn assert_http_error(request: Request<()>, status: StatusCode, code: &str) {
    match timeout(Duration::from_secs(5), connect_async(request))
        .await
        .unwrap()
    {
        Err(Error::Http(response)) => {
            assert_eq!(response.status(), status);
            let body: serde_json::Value =
                serde_json::from_slice(response.body().as_ref().unwrap()).unwrap();
            assert_eq!(body["error"]["code"], code);
        }
        other => panic!("expected HTTP {status}, got {other:?}"),
    }
}

#[tokio::test]
async fn authentication_and_native_client_boundary() {
    let server = Server::start(8, PortPolicy::default()).await;
    let (status, info) = server.get("/v1/info", "").await;
    assert_eq!(status, 200);
    assert_eq!(info["authentication"], "tailscale-owner");
    assert_eq!(info["protocol"], PROTOCOL);
    assert_eq!(server.get("/healthz", "").await.1["status"], "ok");
    assert_eq!(
        server
            .get("/v1/info", "Origin: https://example.com\r\n")
            .await
            .0,
        403
    );
    let mut denied = TcpStream::connect(server.addr).await.unwrap();
    server.identity.deny(denied.local_addr().unwrap());
    denied.write_all(b"GET /v1/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nX-Forwarded-For: 100.64.0.1\r\nTailscale-User-Login: owner@example.com\r\nAuthorization: Bearer invented\r\n\r\n").await.unwrap();
    let mut bytes = Vec::new();
    denied.read_to_end(&mut bytes).await.unwrap();
    assert!(
        String::from_utf8(bytes)
            .unwrap()
            .starts_with("HTTP/1.1 403")
    );
    server.identity.unavailable.store(true, Ordering::SeqCst);
    assert_eq!(server.get("/healthz", "").await.0, 503);
    server.identity.unavailable.store(false, Ordering::SeqCst);
    server.stop().await;
}

#[tokio::test]
async fn policy_and_server_port_are_enforced() {
    let server = Server::start(8, "3000".parse().unwrap()).await;
    assert_http_error(server.request(5173), StatusCode::FORBIDDEN, "port_denied").await;
    server.stop().await;
    let server = Server::start(8, "1-65535".parse().unwrap()).await;
    assert_http_error(
        server.request(server.addr.port()),
        StatusCode::FORBIDDEN,
        "port_denied",
    )
    .await;
    assert_http_error(server.request(0), StatusCode::FORBIDDEN, "port_denied").await;
    server.stop().await;
}

#[tokio::test]
async fn handshake_reports_protocol_and_target_errors() {
    let server = Server::start(8, PortPolicy::default()).await;
    let mut request = server.request(3000);
    request.headers_mut().remove("Sec-WebSocket-Protocol");
    assert_http_error(request, StatusCode::BAD_REQUEST, "protocol_required").await;
    let unused = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = unused.local_addr().unwrap().port();
    drop(unused);
    assert_http_error(
        server.request(port),
        StatusCode::BAD_GATEWAY,
        "target_unavailable",
    )
    .await;
    server.stop().await;
}

#[tokio::test]
async fn forwards_can_be_added_and_removed_independently() {
    let server = Server::start(8, PortPolicy::default()).await;
    let (port_a, echo_a) = echo_server().await;
    let mut first = server.connect(port_a).await;
    first
        .send(Message::Binary(b"\0first".to_vec().into()))
        .await
        .unwrap();
    assert_eq!(next_binary(&mut first).await, b"\0first");

    // Add another remote port without restarting or reconnecting the first.
    let (port_b, echo_b) = echo_server().await;
    let mut second = server.connect(port_b).await;
    second
        .send(Message::Binary(b"\0second".to_vec().into()))
        .await
        .unwrap();
    assert_eq!(next_binary(&mut second).await, b"\0second");
    first.close(None).await.unwrap();
    second
        .send(Message::Binary(b"\0still connected".to_vec().into()))
        .await
        .unwrap();
    assert_eq!(next_binary(&mut second).await, b"\0still connected");
    second.send(Message::Binary(vec![1].into())).await.unwrap();
    assert_eq!(next_binary(&mut second).await, vec![1]);
    assert_eq!(read_close(&mut second).await, 1000);
    timeout(Duration::from_secs(5), echo_a)
        .await
        .unwrap()
        .unwrap();
    timeout(Duration::from_secs(5), echo_b)
        .await
        .unwrap()
        .unwrap();
    server.stop().await;
}

#[tokio::test]
async fn transfers_large_binary_payload_in_both_directions() {
    let server = Server::start(8, PortPolicy::default()).await;
    let (port, echo) = echo_server().await;
    let socket = server.connect(port).await;
    let payload: Vec<u8> = (0..2_000_000).map(|n| (n % 251) as u8).collect();
    let (mut sender, mut receiver) = socket.split();
    let send = async {
        for chunk in payload.chunks(64 * 1024) {
            let mut frame = vec![0];
            frame.extend_from_slice(chunk);
            sender.send(Message::Binary(frame.into())).await.unwrap();
        }
        sender.send(Message::Binary(vec![1].into())).await.unwrap();
    };
    let receive = async {
        let mut received = Vec::new();
        loop {
            match receiver.next().await.unwrap().unwrap() {
                Message::Binary(frame) if frame[0] == 0 => received.extend_from_slice(&frame[1..]),
                Message::Binary(frame) if frame.as_ref() == [1] => break,
                Message::Ping(_) | Message::Pong(_) => {}
                other => panic!("unexpected frame {other:?}"),
            }
        }
        assert_eq!(received, payload);
    };
    timeout(Duration::from_secs(10), async {
        tokio::join!(send, receive);
    })
    .await
    .unwrap();
    echo.await.unwrap();
    server.stop().await;
}

#[tokio::test]
async fn client_half_close_preserves_the_response() {
    let server = Server::start(8, PortPolicy::default()).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let target = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        stream.read_to_end(&mut request).await.unwrap();
        assert_eq!(request, b"request");
        stream.write_all(b"response after EOF").await.unwrap();
        stream.shutdown().await.unwrap();
    });
    let mut socket = server.connect(port).await;
    socket
        .send(Message::Binary(b"\0request".to_vec().into()))
        .await
        .unwrap();
    socket.send(Message::Binary(vec![1].into())).await.unwrap();
    assert_eq!(next_binary(&mut socket).await, b"\0response after EOF");
    assert_eq!(next_binary(&mut socket).await, vec![1]);
    assert_eq!(read_close(&mut socket).await, 1000);
    target.await.unwrap();
    server.stop().await;
}

#[tokio::test]
async fn target_half_close_keeps_client_write_direction_open() {
    let server = Server::start(8, PortPolicy::default()).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let target = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        stream.write_all(b"hello").await.unwrap();
        stream.shutdown().await.unwrap();
        let mut response = Vec::new();
        stream.read_to_end(&mut response).await.unwrap();
        assert_eq!(response, b"late response");
    });
    let mut socket = server.connect(port).await;
    assert_eq!(next_binary(&mut socket).await, b"\0hello");
    assert_eq!(next_binary(&mut socket).await, vec![1]);
    socket
        .send(Message::Binary(b"\0late response".to_vec().into()))
        .await
        .unwrap();
    socket.send(Message::Binary(vec![1].into())).await.unwrap();
    assert_eq!(read_close(&mut socket).await, 1000);
    target.await.unwrap();
    server.stop().await;
}

#[tokio::test]
async fn invalid_frames_close_only_their_tunnel() {
    let server = Server::start(8, PortPolicy::default()).await;
    for frame in [
        Message::Text("no text".into()),
        Message::Binary(vec![2].into()),
        Message::Binary(vec![1, 0].into()),
        Message::Binary(Vec::new().into()),
    ] {
        let (port, echo) = echo_server().await;
        let mut socket = server.connect(port).await;
        socket.send(frame).await.unwrap();
        assert_eq!(read_close(&mut socket).await, 1002);
        timeout(Duration::from_secs(5), echo)
            .await
            .unwrap()
            .unwrap();
    }
    let auth = String::new();
    assert_eq!(server.get("/healthz", &auth).await.0, 200);
    server.stop().await;
}

#[tokio::test]
async fn capacity_is_released_after_a_tunnel_closes() {
    let server = Server::start(1, PortPolicy::default()).await;
    let (port, echo) = echo_server().await;
    let mut socket = server.connect(port).await;
    assert_http_error(
        server.request(port),
        StatusCode::SERVICE_UNAVAILABLE,
        "capacity_exceeded",
    )
    .await;
    socket.send(Message::Binary(vec![1].into())).await.unwrap();
    assert_eq!(next_binary(&mut socket).await, vec![1]);
    assert_eq!(read_close(&mut socket).await, 1000);
    echo.await.unwrap();
    let (new_port, new_echo) = echo_server().await;
    let mut replacement = server.connect(new_port).await;
    replacement.close(None).await.unwrap();
    timeout(Duration::from_secs(5), new_echo)
        .await
        .unwrap()
        .unwrap();
    server.stop().await;
}

#[tokio::test]
async fn shutdown_closes_active_tunnels_and_target_connections() {
    let server = Server::start(8, PortPolicy::default()).await;
    let (port, echo) = echo_server().await;
    let mut socket = server.connect(port).await;
    server.shutdown.cancel();
    assert_eq!(read_close(&mut socket).await, 1001);
    timeout(Duration::from_secs(5), echo)
        .await
        .unwrap()
        .unwrap();
    server.stop().await;
}

#[tokio::test]
async fn ipv6_loopback_targets_are_supported() {
    let server = Server::start(8, PortPolicy::default()).await;
    let listener = TcpListener::bind("[::1]:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let target = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        stream.write_all(b"ipv6").await.unwrap();
    });
    let mut request = server.request(port);
    *request.uri_mut() = format!("ws://{}/v1/tunnels/{port}?family=ipv6", server.addr)
        .parse()
        .unwrap();
    let (mut socket, _) = connect_async(request).await.unwrap();
    assert_eq!(next_binary(&mut socket).await, b"\0ipv6");
    socket.close(None).await.unwrap();
    target.await.unwrap();
    server.stop().await;
}
