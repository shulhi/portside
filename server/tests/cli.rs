use std::path::PathBuf;
use std::process::Command;

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/tailscale.py")
}

#[test]
fn legacy_token_configuration_is_removed() {
    let result = Command::new(env!("CARGO_BIN_EXE_portside-server"))
        .args(["generate-token", "--output", "/tmp/unused"])
        .output()
        .unwrap();
    assert!(!result.status.success());
    let result = Command::new(env!("CARGO_BIN_EXE_portside-server"))
        .args(["serve", "--token-file", "/tmp/unused"])
        .output()
        .unwrap();
    assert!(!result.status.success());
}

#[test]
fn wildcard_bind_is_refused_at_startup() {
    let result = Command::new(env!("CARGO_BIN_EXE_portside-server"))
        .args(["serve", "--listen", "0.0.0.0:9417", "--tailscale-bin"])
        .arg(fixture())
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("wildcard"));
}

#[test]
fn unavailable_tailscale_refuses_startup() {
    let result = Command::new(env!("CARGO_BIN_EXE_portside-server"))
        .args([
            "serve",
            "--tailscale-bin",
            "/nonexistent/portside-tailscale-test",
        ])
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("cannot read Tailscale identity"));
}

#[test]
fn supervised_server_stops_when_parent_pipe_closes() {
    use std::{
        io::Write,
        net::TcpStream,
        process::Stdio,
        thread,
        time::{Duration, Instant},
    };

    let fixture = fixture();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let mut child = Command::new(env!("CARGO_BIN_EXE_portside-server"))
        .args(["serve", "--listen", &address.to_string(), "--tailscale-bin"])
        .arg(&fixture)
        .arg("--shutdown-on-stdin-eof")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while TcpStream::connect_timeout(&address, Duration::from_millis(100)).is_err() {
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("supervised server did not start");
        }
        thread::sleep(Duration::from_millis(10));
    }
    assert!(child.try_wait().unwrap().is_none());
    let mut parent = child.stdin.take().unwrap();
    parent.write_all(b"parent still alive").unwrap();
    drop(parent);
    let deadline = Instant::now() + Duration::from_secs(7);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("server outlived its supervising pipe");
        }
        thread::sleep(Duration::from_millis(10));
    }
}
