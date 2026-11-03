use std::{net::SocketAddr, path::PathBuf};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use portside_server::{
    auth::TailscaleAuth,
    config::{PortPolicy, ServerConfig},
    serve,
};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(
    version,
    about = "Dynamic TCP tunnels over your existing Tailscale connection"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the server on a loopback or Tailscale address.
    Serve {
        #[arg(long, default_value = "127.0.0.1:9417")]
        listen: SocketAddr,
        #[arg(long, default_value = "tailscale")]
        tailscale_bin: PathBuf,
        #[arg(long, default_value = "1024-65535")]
        allowed_ports: PortPolicy,
        #[arg(long, default_value_t = 128, value_parser = clap::value_parser!(u16).range(1..))]
        max_tunnels: u16,
        /// Allow authenticated file uploads into this directory and its subfolders.
        #[arg(long)]
        upload_dir: Option<PathBuf>,
        /// Maximum size of each uploaded file in bytes (default: 100 MiB).
        #[arg(long, default_value_t = 100 * 1024 * 1024, value_parser = clap::value_parser!(u64).range(1..))]
        max_upload_bytes: u64,
        /// Stop when the supervising application's stdin pipe closes.
        #[arg(long)]
        shutdown_on_stdin_eof: bool,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();
    match Cli::parse().command {
        Command::Serve {
            listen,
            tailscale_bin,
            allowed_ports,
            max_tunnels,
            upload_dir,
            max_upload_bytes,
            shutdown_on_stdin_eof,
        } => {
            let auth = TailscaleAuth::discover(tailscale_bin).await?;
            let config = ServerConfig {
                listen,
                auth,
                allowed_ports,
                max_tunnels: max_tunnels as usize,
                upload_dir,
                max_upload_bytes,
            };
            config.validate()?;
            let listener = TcpListener::bind(listen).await.context("cannot bind server; confirm Tailscale is connected and the address belongs to this machine")?;
            let shutdown = CancellationToken::new();
            if shutdown_on_stdin_eof {
                let parent_shutdown = shutdown.clone();
                // A plain thread avoids an uncancellable Tokio blocking-stdin task
                // keeping the runtime alive after a signal-triggered shutdown.
                std::thread::spawn(move || {
                    use std::io::Read;
                    let mut input = std::io::stdin().lock();
                    let mut buffer = [0; 256];
                    loop {
                        match input.read(&mut buffer) {
                            Ok(0) | Err(_) => break,
                            Ok(_) => {}
                        }
                    }
                    parent_shutdown.cancel();
                });
            }
            let signal_shutdown = shutdown.clone();
            let signal_task = tokio::spawn(async move {
                if let Err(error) = wait_for_signal().await {
                    tracing::error!(%error, "cannot install signal handler");
                }
                signal_shutdown.cancel();
            });
            let result = serve(listener, config, shutdown).await;
            signal_task.abort();
            result
        }
    }
}

async fn wait_for_signal() -> Result<()> {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let mut terminate = signal(SignalKind::terminate())?;
        tokio::select! {
            result = tokio::signal::ctrl_c() => result?,
            _ = terminate.recv() => {},
        }
    }
    #[cfg(not(unix))]
    tokio::signal::ctrl_c().await?;
    Ok(())
}
