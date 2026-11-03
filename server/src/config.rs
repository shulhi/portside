use std::{
    net::{IpAddr, SocketAddr},
    ops::RangeInclusive,
    path::PathBuf,
    str::FromStr,
};

use crate::auth::TailscaleAuth;
use anyhow::{Result, bail};

pub const PROTOCOL: &str = "portside.tcp.v1";
pub const MAX_DATA_SIZE: usize = 64 * 1024;

#[derive(Clone, Debug)]
pub struct PortPolicy(Vec<RangeInclusive<u16>>);

impl Default for PortPolicy {
    fn default() -> Self {
        Self(vec![1024..=65535])
    }
}

impl FromStr for PortPolicy {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        let mut ranges = Vec::new();
        for part in value.split(',') {
            let part = part.trim();
            let (start, end) = match part.split_once('-') {
                Some((start, end)) => (start.parse::<u16>()?, end.parse::<u16>()?),
                None => {
                    let port = part.parse::<u16>()?;
                    (port, port)
                }
            };
            if start == 0 || start > end {
                bail!("port ranges must be ascending and between 1 and 65535");
            }
            ranges.push(start..=end);
        }
        Ok(Self(ranges))
    }
}

impl PortPolicy {
    pub fn allows(&self, port: u16) -> bool {
        self.0.iter().any(|range| range.contains(&port))
    }

    pub fn ranges(&self) -> Vec<String> {
        self.0
            .iter()
            .map(|range| {
                if range.start() == range.end() {
                    range.start().to_string()
                } else {
                    format!("{}-{}", range.start(), range.end())
                }
            })
            .collect()
    }
}

#[derive(Clone)]
pub struct ServerConfig {
    pub listen: SocketAddr,
    pub auth: TailscaleAuth,
    pub allowed_ports: PortPolicy,
    pub max_tunnels: usize,
    pub upload_dir: Option<PathBuf>,
    pub max_upload_bytes: u64,
}

impl ServerConfig {
    pub fn validate(&self) -> Result<()> {
        if !is_private_bind(self.listen.ip()) {
            bail!(
                "listen address must be a loopback or Tailscale IP; wildcard and LAN/public binds are refused"
            );
        }
        if self.max_tunnels == 0 {
            bail!("max-tunnels must be greater than zero");
        }
        if self.max_upload_bytes == 0 {
            bail!("max-upload-bytes must be greater than zero");
        }
        Ok(())
    }
}

fn is_private_bind(ip: IpAddr) -> bool {
    if ip.is_loopback() {
        return true;
    }
    match ip {
        IpAddr::V4(ip) => {
            let octets = ip.octets();
            octets[0] == 100 && (64..=127).contains(&octets[1])
        }
        IpAddr::V6(ip) => ip.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binding_boundaries() {
        for ip in [
            "127.0.0.1",
            "::1",
            "100.64.0.1",
            "100.127.255.254",
            "fd7a:115c:a1e0::1",
        ] {
            assert!(is_private_bind(ip.parse().unwrap()), "{ip}");
        }
        for ip in [
            "0.0.0.0",
            "::",
            "192.168.1.2",
            "100.63.255.255",
            "100.128.0.0",
            "fd7a:115c:a1e1::1",
            "::ffff:100.64.0.1",
        ] {
            assert!(!is_private_bind(ip.parse().unwrap()), "{ip}");
        }
    }

    #[test]
    fn policy_validation_and_boundaries() {
        let policy: PortPolicy = "3000,5173,8000-8100".parse().unwrap();
        for port in [3000, 5173, 8000, 8100] {
            assert!(policy.allows(port));
        }
        for port in [0, 22, 7999, 8101] {
            assert!(!policy.allows(port));
        }
        for invalid in ["", "0", "65536", "8100-8000", "3000,", "1-2-3"] {
            assert!(invalid.parse::<PortPolicy>().is_err(), "{invalid}");
        }
    }
}
