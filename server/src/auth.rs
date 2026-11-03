//! Authentication is derived exclusively from the accepted socket's peer address.
use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::{
    future::Future,
    net::SocketAddr,
    path::{Path, PathBuf},
    pin::Pin,
    process::Stdio,
    sync::Arc,
    time::Duration,
};
use tokio::{process::Command, sync::Semaphore, time};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthError {
    Forbidden,
    Unavailable,
}

#[derive(Clone, Debug)]
pub struct PeerIdentity {
    pub user_id: u64,
    pub node_id: String,
    pub tagged: bool,
}

pub type IdentityFuture<'a> =
    Pin<Box<dyn Future<Output = Result<PeerIdentity, AuthError>> + Send + 'a>>;

/// Injectable identity transport; production uses the installed Tailscale CLI's LocalAPI client.
pub trait IdentitySource: Send + Sync {
    fn whois(&self, peer: SocketAddr) -> IdentityFuture<'_>;
}

#[derive(Clone)]
pub struct TailscaleAuth {
    owner: u64,
    source: Arc<dyn IdentitySource>,
    capacity: Arc<Semaphore>,
}

impl TailscaleAuth {
    pub fn new(owner: u64, source: Arc<dyn IdentitySource>) -> Result<Self> {
        anyhow::ensure!(owner > 0, "a Tailscale device owner is required");
        Ok(Self {
            owner,
            source,
            capacity: Arc::new(Semaphore::new(16)),
        })
    }

    pub async fn discover(binary: PathBuf) -> Result<Self> {
        let status = cli_json(&binary, &["status", "--json"]).await
            .context("cannot read Tailscale identity; install Tailscale and connect it before starting Portside")?;
        let status: Status =
            serde_json::from_slice(&status).context("invalid Tailscale status response")?;
        anyhow::ensure!(
            status.backend_state == "Running",
            "Tailscale must be connected"
        );
        anyhow::ensure!(
            status.node.tags.is_empty(),
            "the server must be a user-owned Tailscale device, not a tagged device"
        );
        Self::new(status.node.user_id, Arc::new(CliSource { binary }))
    }

    pub async fn authorize(&self, peer: SocketAddr) -> Result<(), AuthError> {
        let _permit = self
            .capacity
            .try_acquire()
            .map_err(|_| AuthError::Unavailable)?;
        let identity = time::timeout(Duration::from_secs(4), self.source.whois(peer))
            .await
            .map_err(|_| AuthError::Unavailable)??;
        if identity.user_id != self.owner || identity.tagged || identity.node_id.is_empty() {
            return Err(AuthError::Forbidden);
        }
        Ok(())
    }
}

struct CliSource {
    binary: PathBuf,
}
impl IdentitySource for CliSource {
    fn whois(&self, peer: SocketAddr) -> IdentityFuture<'_> {
        Box::pin(async move {
            let output = cli_json(
                &self.binary,
                &["whois", "--json", "--proto=tcp", &peer.to_string()],
            )
            .await
            .map_err(|_| AuthError::Unavailable)?;
            parse_whois(&output)
        })
    }
}

async fn cli_json(binary: &Path, arguments: &[&str]) -> Result<Vec<u8>> {
    let output = time::timeout(
        Duration::from_secs(3),
        Command::new(binary)
            .args(arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .context("Tailscale identity lookup timed out")??;
    if !output.status.success() {
        bail!("Tailscale identity lookup failed");
    }
    anyhow::ensure!(
        output.stdout.len() <= 4 * 1024 * 1024,
        "Tailscale identity response is too large"
    );
    Ok(output.stdout)
}

#[derive(Deserialize)]
struct Status {
    #[serde(rename = "BackendState")]
    backend_state: String,
    #[serde(rename = "Self")]
    node: SelfNode,
}
#[derive(Deserialize)]
struct SelfNode {
    #[serde(rename = "UserID")]
    user_id: u64,
    #[serde(rename = "Tags", default, deserialize_with = "nullable_tags")]
    tags: Vec<String>,
}
fn nullable_tags<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<String>, D::Error> {
    Ok(Option::<Vec<String>>::deserialize(d)?.unwrap_or_default())
}
#[derive(Deserialize)]
struct WhoIs {
    #[serde(rename = "Node")]
    node: Node,
    #[serde(rename = "UserProfile")]
    profile: User,
}
#[derive(Deserialize)]
struct Node {
    #[serde(rename = "StableID")]
    id: String,
    #[serde(rename = "User")]
    user: u64,
    #[serde(rename = "Tags", default, deserialize_with = "nullable_tags")]
    tags: Vec<String>,
}
#[derive(Deserialize)]
struct User {
    #[serde(rename = "ID")]
    id: u64,
}

fn parse_whois(bytes: &[u8]) -> Result<PeerIdentity, AuthError> {
    let response: WhoIs = serde_json::from_slice(bytes).map_err(|_| AuthError::Unavailable)?;
    if response.node.user == 0 || response.node.user != response.profile.id {
        return Err(AuthError::Forbidden);
    }
    Ok(PeerIdentity {
        user_id: response.node.user,
        node_id: response.node.id,
        tagged: !response.node.tags.is_empty(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Source {
        user: u64,
        tagged: bool,
        fail: bool,
    }
    impl IdentitySource for Source {
        fn whois(&self, _: SocketAddr) -> IdentityFuture<'_> {
            Box::pin(async move {
                if self.fail {
                    return Err(AuthError::Unavailable);
                }
                Ok(PeerIdentity {
                    user_id: self.user,
                    tagged: self.tagged,
                    node_id: "test-node".into(),
                })
            })
        }
    }
    #[tokio::test]
    async fn permits_only_owner_devices_and_fails_closed() {
        for (user, tagged, fail, expected) in [
            (7, false, false, Ok(())),
            (8, false, false, Err(AuthError::Forbidden)),
            (7, true, false, Err(AuthError::Forbidden)),
            (7, false, true, Err(AuthError::Unavailable)),
        ] {
            let auth = TailscaleAuth::new(7, Arc::new(Source { user, tagged, fail })).unwrap();
            assert_eq!(
                auth.authorize("100.64.0.1:1234".parse().unwrap()).await,
                expected
            );
        }
    }
    #[test]
    fn rejects_missing_inconsistent_and_malformed_identity() {
        for bytes in [
            b"{}".as_slice(),
            b"not-json",
            br#"{"Node":{"StableID":"node","User":7},"UserProfile":{"ID":8}}"#,
        ] {
            assert!(parse_whois(bytes).is_err());
        }
        let identity = parse_whois(
            br#"{"Node":{"StableID":"node","User":7,"Tags":null},"UserProfile":{"ID":7}}"#,
        )
        .unwrap();
        assert_eq!(identity.user_id, 7);
        assert!(!identity.tagged);
    }
}
