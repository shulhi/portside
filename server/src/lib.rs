pub mod config;
mod tunnel;
mod uploads;

use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use axum::{
    Json, Router,
    extract::{Path, Query, Request, State, WebSocketUpgrade},
    http::{HeaderMap, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, put},
};
use serde::{Deserialize, Serialize};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::Semaphore,
    time,
};
use tokio_util::{sync::CancellationToken, task::TaskTracker};

use config::{MAX_DATA_SIZE, PROTOCOL, ServerConfig};

#[derive(Clone)]
struct AppState {
    config: Arc<ServerConfig>,
    capacity: Arc<Semaphore>,
    shutdown: CancellationToken,
    tasks: TaskTracker,
    uploads: Option<Arc<uploads::UploadStore>>,
    upload_capacity: Arc<Semaphore>,
}

/// The listener must use the validated address in config. Port zero is supported
/// for tests/embedding; the actual bound port is used for self-target protection.
pub async fn serve(
    listener: TcpListener,
    mut config: ServerConfig,
    shutdown: CancellationToken,
) -> anyhow::Result<()> {
    config.validate()?;
    let bound = listener.local_addr()?;
    anyhow::ensure!(
        bound.ip() == config.listen.ip()
            && (config.listen.port() == 0 || bound.port() == config.listen.port()),
        "listener does not match configured address"
    );
    config.listen = bound;
    let uploads = if let Some(directory) = config.upload_dir.clone() {
        let limit = config.max_upload_bytes;
        Some(Arc::new(
            tokio::task::spawn_blocking(move || uploads::UploadStore::new(directory, limit))
                .await??,
        ))
    } else {
        None
    };
    let state = AppState {
        capacity: Arc::new(Semaphore::new(config.max_tunnels)),
        config: Arc::new(config),
        shutdown: shutdown.clone(),
        tasks: TaskTracker::new(),
        uploads,
        upload_capacity: Arc::new(Semaphore::new(4)),
    };
    let app = Router::new()
        .route(
            "/healthz",
            get(|| async { Json(serde_json::json!({"status": "ok"})) }),
        )
        .route("/v1/info", get(info))
        .route("/v1/tunnels/{port}", get(open_tunnel))
        .route("/v1/files", put(uploads::upload))
        .fallback(|| async {
            ApiError::new(
                StatusCode::NOT_FOUND,
                "not_found",
                "endpoint does not exist",
            )
        })
        .layer(middleware::from_fn_with_state(state.clone(), authorize))
        .with_state(state.clone());

    tracing::info!(listen = %bound, max_tunnels = state.config.max_tunnels, "Portside server listening");
    let result = axum::serve(listener, app)
        .with_graceful_shutdown(shutdown.clone().cancelled_owned())
        .await;
    // Upgraded WebSockets are managed separately from HTTP by axum.
    shutdown.cancel();
    state.tasks.close();
    time::timeout(Duration::from_secs(5), state.tasks.wait())
        .await
        .map_err(|_| anyhow::anyhow!("tunnels did not finish shutting down within five seconds"))?;
    result?;
    Ok(())
}

async fn authorize(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let authorized = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.as_bytes().strip_prefix(b"Bearer "))
        .is_some_and(|candidate| state.config.token.matches(candidate));
    let mut response = if !authorized {
        let mut response = ApiError::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "valid bearer token required",
        )
        .into_response();
        response
            .headers_mut()
            .insert(header::WWW_AUTHENTICATE, "Bearer".parse().unwrap());
        response
    } else if request.headers().contains_key(header::ORIGIN) {
        ApiError::new(
            StatusCode::FORBIDDEN,
            "browser_origin",
            "connect using a native Portside client",
        )
        .into_response()
    } else {
        next.run(request).await
    };
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    response
}

async fn info(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "name": "portside-server",
        "version": env!("CARGO_PKG_VERSION"),
        "protocol": PROTOCOL,
        "allowed_ports": state.config.allowed_ports.ranges(),
        "excluded_ports": [state.config.listen.port()],
        "max_tunnels": state.config.max_tunnels,
        "active_tunnels": state.config.max_tunnels - state.capacity.available_permits(),
        "max_data_size": MAX_DATA_SIZE,
        "loopback_families": ["ipv4", "ipv6"],
        "uploads": state.uploads.as_ref().map(|store| store.info()),
    }))
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Family {
    #[default]
    Ipv4,
    Ipv6,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct TunnelQuery {
    #[serde(default)]
    family: Family,
}

async fn open_tunnel(
    State(state): State<AppState>,
    Path(port): Path<u16>,
    Query(query): Query<TunnelQuery>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    if state.shutdown.is_cancelled() {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "shutting_down",
            "server is shutting down",
        ));
    }
    if !state.config.allowed_ports.allows(port) || port == state.config.listen.port() {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "port_denied",
            "target port is not allowed",
        ));
    }
    let has_protocol = headers
        .get_all(header::SEC_WEBSOCKET_PROTOCOL)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .any(|value| value.trim() == PROTOCOL);
    if !has_protocol {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "protocol_required",
            "request WebSocket subprotocol portside.tcp.v1",
        ));
    }
    let permit = state.capacity.clone().try_acquire_owned().map_err(|_| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "capacity_exceeded",
            "maximum concurrent tunnels reached",
        )
    })?;
    let ip = match query.family {
        Family::Ipv4 => IpAddr::V4(Ipv4Addr::LOCALHOST),
        Family::Ipv6 => IpAddr::V6(Ipv6Addr::LOCALHOST),
    };
    let target_addr = SocketAddr::new(ip, port);
    let target = tokio::select! {
        _ = state.shutdown.cancelled() => return Err(ApiError::new(StatusCode::SERVICE_UNAVAILABLE, "shutting_down", "server is shutting down")),
        result = time::timeout(Duration::from_secs(3), TcpStream::connect(target_addr)) => {
            match result {
                Ok(Ok(target)) => target,
                Ok(Err(_)) => return Err(ApiError::new(StatusCode::BAD_GATEWAY, "target_unavailable", "cannot connect to target loopback port")),
                Err(_) => return Err(ApiError::new(StatusCode::GATEWAY_TIMEOUT, "target_timeout", "target connection timed out")),
            }
        }
    };
    // Register before upgrade so shutdown also waits for pending upgrades.
    let task = state.tasks.token();
    Ok(ws
        .protocols([PROTOCOL])
        .write_buffer_size(0)
        .max_message_size(MAX_DATA_SIZE + 1)
        .max_frame_size(MAX_DATA_SIZE + 1)
        .max_write_buffer_size(128 * 1024)
        .on_upgrade(move |socket| async move {
            let _task = task;
            let _permit = permit;
            tracing::debug!(target = %target_addr, "tunnel opened");
            tunnel::relay(socket, target, state.shutdown).await;
        }))
}

struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: &'static str,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: &'static str) -> Self {
        Self {
            status,
            code,
            message,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        #[derive(Serialize)]
        struct Body {
            error: ErrorDetail,
        }
        #[derive(Serialize)]
        struct ErrorDetail {
            code: &'static str,
            message: &'static str,
        }
        (
            self.status,
            Json(Body {
                error: ErrorDetail {
                    code: self.code,
                    message: self.message,
                },
            }),
        )
            .into_response()
    }
}
