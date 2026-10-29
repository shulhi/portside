use std::{
    fs::{self, OpenOptions},
    io::Write,
    net::SocketAddr,
    path::PathBuf,
};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use portside_server::{
    config::{PortPolicy, ServerConfig, Token},
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
    /// Create a new 256-bit bearer token file (refuses to overwrite a file).
    GenerateToken {
        #[arg(long)]
        output: PathBuf,
    },
    /// Run the server on a loopback or Tailscale address.
    Serve {
        #[arg(long, default_value = "127.0.0.1:9417")]
        listen: SocketAddr,
        #[arg(long)]
        token_file: PathBuf,
        #[arg(long, default_value = "1024-65535")]
        allowed_ports: PortPolicy,
        #[arg(long, default_value_t = 128, value_parser = clap::value_parser!(u16).range(1..))]
        max_tunnels: u16,
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
        Command::GenerateToken { output } => generate_token(output),
        Command::Serve {
            listen,
            token_file,
            allowed_ports,
            max_tunnels,
        } => {
            let metadata = fs::metadata(&token_file)
                .context("cannot read token file; create one using generate-token")?;
            if metadata.len() > 1024 {
                bail!("token file is too large");
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if metadata.permissions().mode() & 0o077 != 0 {
                    bail!("token file must not be accessible by other users; run chmod 600 on it");
                }
            }
            let token: Token = fs::read_to_string(&token_file)
                .context("cannot read token file")?
                .parse()?;
            let config = ServerConfig {
                listen,
                token,
                allowed_ports,
                max_tunnels: max_tunnels as usize,
            };
            config.validate()?;
            let listener = TcpListener::bind(listen).await.context("cannot bind server; confirm Tailscale is connected and the address belongs to this machine")?;
            let shutdown = CancellationToken::new();
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

fn generate_token(output: PathBuf) -> Result<()> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("cannot obtain secure random bytes: {error}"))?;
    let token: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&output)
        .context("cannot create token file (existing files are never overwritten)")?;
    writeln!(file, "{token}").context("cannot write token file")?;
    file.sync_all().context("cannot sync token file")?;
    tracing::info!(path = %output.display(), "created token file; securely copy this token to your client");
    Ok(())
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
