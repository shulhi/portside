use std::{fs, net::SocketAddr, path::PathBuf, time::Duration};

use portside_server::{
    config::{PortPolicy, ServerConfig},
    serve,
};
use serde_json::Value;
use tempfile::TempDir;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
    time::{sleep, timeout},
};
use tokio_util::sync::CancellationToken;

const TOKEN: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

struct Server {
    _directory: TempDir,
    root: PathBuf,
    address: SocketAddr,
    shutdown: CancellationToken,
    task: JoinHandle<anyhow::Result<()>>,
}

impl Server {
    async fn start(enabled: bool, limit: u64) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("uploads");
        fs::create_dir(&root).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let shutdown = CancellationToken::new();
        let config = ServerConfig {
            listen: address,
            token: TOKEN.parse().unwrap(),
            allowed_ports: PortPolicy::default(),
            max_tunnels: 8,
            upload_dir: enabled.then(|| root.clone()),
            max_upload_bytes: limit,
        };
        let task = tokio::spawn(serve(listener, config, shutdown.clone()));
        Self {
            _directory: directory,
            root,
            address,
            shutdown,
            task,
        }
    }

    async fn request(
        &self,
        method: &str,
        target: &str,
        auth: bool,
        data: &[u8],
        chunked: bool,
    ) -> (u16, Value) {
        let mut socket = TcpStream::connect(self.address).await.unwrap();
        let auth = if auth {
            format!("Authorization: Bearer {TOKEN}\r\n")
        } else {
            String::new()
        };
        let length = if chunked {
            "Transfer-Encoding: chunked\r\n".to_string()
        } else {
            format!("Content-Length: {}\r\n", data.len())
        };
        let mut request = format!(
            "{method} {target} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n{auth}{length}\r\n",
            self.address
        )
        .into_bytes();
        if chunked {
            for chunk in data.chunks(64) {
                request.extend_from_slice(format!("{:x}\r\n", chunk.len()).as_bytes());
                request.extend_from_slice(chunk);
                request.extend_from_slice(b"\r\n");
            }
            request.extend_from_slice(b"0\r\n\r\n");
        } else {
            request.extend_from_slice(data);
        }
        socket.write_all(&request).await.unwrap();
        let mut response = Vec::new();
        timeout(Duration::from_secs(5), socket.read_to_end(&mut response))
            .await
            .unwrap()
            .unwrap();
        let split = response
            .windows(4)
            .position(|bytes| bytes == b"\r\n\r\n")
            .unwrap();
        let status = std::str::from_utf8(&response[..split])
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .parse()
            .unwrap();
        (
            status,
            serde_json::from_slice(&response[split + 4..]).unwrap(),
        )
    }

    async fn stop(self) {
        self.shutdown.cancel();
        timeout(Duration::from_secs(5), self.task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn uploads_are_opt_in_and_authenticated() {
    let server = Server::start(false, 1024).await;
    assert!(server.request("GET", "/v1/info", true, b"", false).await.1["uploads"].is_null());
    assert_eq!(
        server
            .request("PUT", "/v1/files?filename=x.png", true, b"image", false)
            .await
            .0,
        404
    );
    server.stop().await;
    let server = Server::start(true, 1024).await;
    assert_eq!(
        server
            .request("PUT", "/v1/files?filename=x.png", false, b"image", false)
            .await
            .0,
        401
    );
    assert_eq!(fs::read_dir(&server.root).unwrap().count(), 0);
    let (_, info) = server.request("GET", "/v1/info", true, b"", false).await;
    assert_eq!(info["uploads"]["max_file_size"], 1024);
    server.stop().await;
}

#[tokio::test]
async fn streams_large_files_and_returns_a_real_absolute_path() {
    let server = Server::start(true, 4 * 1024 * 1024).await;
    let bytes: Vec<u8> = (0..3 * 1024 * 1024)
        .map(|index| (index % 251) as u8)
        .collect();
    let (status, result) = server
        .request(
            "PUT",
            "/v1/files?filename=sample%20%26%20data.bin&folder=project/screenshots",
            true,
            &bytes,
            false,
        )
        .await;
    assert_eq!(status, 201, "{result}");
    assert_eq!(result["bytes"], bytes.len());
    assert_eq!(result["name"], "sample & data.bin");
    let path = PathBuf::from(result["path"].as_str().unwrap());
    assert!(path.is_absolute());
    assert!(path.starts_with(fs::canonicalize(server.root.join("project/screenshots")).unwrap()));
    assert_eq!(fs::read(&path).unwrap(), bytes);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert_eq!(
        fs::read_dir(server.root.join("project/screenshots"))
            .unwrap()
            .count(),
        1
    );
    server.stop().await;
}

#[tokio::test]
async fn duplicate_names_never_replace_files() {
    let server = Server::start(true, 1024).await;
    let (_, first) = server
        .request("PUT", "/v1/files?filename=image.png", true, b"first", false)
        .await;
    let (_, second) = server
        .request(
            "PUT",
            "/v1/files?filename=image.png",
            true,
            b"second",
            false,
        )
        .await;
    assert_ne!(first["path"], second["path"]);
    assert_eq!(fs::read(first["path"].as_str().unwrap()).unwrap(), b"first");
    assert_eq!(
        fs::read(second["path"].as_str().unwrap()).unwrap(),
        b"second"
    );
    server.stop().await;
}

#[tokio::test]
async fn rejects_path_traversal_and_invalid_filenames() {
    let server = Server::start(true, 1024).await;
    for target in [
        "?filename=../secret",
        "?filename=..",
        "?filename=",
        "?filename=a%5Cb",
        "?filename=a%00b",
        "?filename=x&folder=..",
        "?filename=x&folder=../escape",
        "?filename=x&folder=/tmp",
        "?filename=x&folder=a/./b",
        "?filename=x&folder=a//b",
    ] {
        let (status, error) = server
            .request(
                "PUT",
                &format!("/v1/files{target}"),
                true,
                b"blocked",
                false,
            )
            .await;
        assert_eq!(status, 400, "{target}: {error}");
    }
    assert_eq!(fs::read_dir(&server.root).unwrap().count(), 0);
    server.stop().await;
}

#[cfg(unix)]
#[tokio::test]
async fn symlinks_cannot_escape_the_upload_root() {
    use std::os::unix::fs::symlink;
    let server = Server::start(true, 1024).await;
    let outside = tempfile::tempdir().unwrap();
    symlink(outside.path(), server.root.join("escape")).unwrap();
    let (status, error) = server
        .request(
            "PUT",
            "/v1/files?filename=secret&folder=escape/nested",
            true,
            b"blocked",
            false,
        )
        .await;
    assert_eq!(status, 403, "{error}");
    assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 0);
    server.stop().await;
}

#[tokio::test]
async fn size_limits_apply_to_declared_and_chunked_bodies() {
    let server = Server::start(true, 128).await;
    for chunked in [false, true] {
        let (status, error) = server
            .request("PUT", "/v1/files?filename=large", true, &[7; 256], chunked)
            .await;
        assert_eq!(status, 413, "{error}");
        assert_eq!(error["error"]["code"], "file_too_large");
        assert_eq!(fs::read_dir(&server.root).unwrap().count(), 0);
    }
    server.stop().await;
}

#[tokio::test]
async fn interrupted_uploads_leave_no_partial_files() {
    let server = Server::start(true, 1024).await;
    let mut socket = TcpStream::connect(server.address).await.unwrap();
    socket.write_all(format!("PUT /v1/files?filename=incomplete HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 1000\r\n\r\npart").as_bytes()).await.unwrap();
    for _ in 0..100 {
        if fs::read_dir(&server.root).unwrap().count() > 0 {
            break;
        }
        sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(fs::read_dir(&server.root).unwrap().count(), 1);
    drop(socket);
    for _ in 0..100 {
        if fs::read_dir(&server.root).unwrap().count() == 0 {
            break;
        }
        sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(fs::read_dir(&server.root).unwrap().count(), 0);
    server.stop().await;
}
