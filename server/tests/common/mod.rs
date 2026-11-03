#![allow(dead_code)]
use portside_server::auth::{
    AuthError, IdentityFuture, IdentitySource, PeerIdentity, TailscaleAuth,
};
use std::{
    collections::HashSet,
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

#[derive(Default)]
pub struct TestIdentity {
    denied: Mutex<HashSet<SocketAddr>>,
    pub unavailable: AtomicBool,
    pub seen: Mutex<Vec<SocketAddr>>,
}
impl TestIdentity {
    pub fn auth(self: &Arc<Self>) -> TailscaleAuth {
        TailscaleAuth::new(7, self.clone()).unwrap()
    }
    pub fn deny(&self, peer: SocketAddr) {
        self.denied.lock().unwrap().insert(peer);
    }
}
impl IdentitySource for TestIdentity {
    fn whois(&self, peer: SocketAddr) -> IdentityFuture<'_> {
        Box::pin(async move {
            self.seen.lock().unwrap().push(peer);
            if self.unavailable.load(Ordering::SeqCst) {
                return Err(AuthError::Unavailable);
            }
            Ok(PeerIdentity {
                user_id: if self.denied.lock().unwrap().contains(&peer) {
                    8
                } else {
                    7
                },
                node_id: "test-node".into(),
                tagged: false,
            })
        })
    }
}
