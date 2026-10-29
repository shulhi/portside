use std::time::Duration;

use axum::extract::ws::{CloseFrame, Message, WebSocket};
use futures_util::{SinkExt, StreamExt};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::oneshot,
    time,
};
use tokio_util::sync::CancellationToken;

use crate::config::MAX_DATA_SIZE;

#[derive(Debug)]
enum End {
    Disconnected,
    Protocol,
    Io,
    Idle,
    Shutdown,
}

pub(crate) async fn relay(socket: WebSocket, target: TcpStream, shutdown: CancellationToken) {
    let _ = target.set_nodelay(true);
    let (mut sender, mut receiver) = socket.split();
    let (mut target_reader, mut target_writer) = target.into_split();
    let (client_eof_tx, client_eof_rx) = oneshot::channel();

    let outcome = {
        let inbound = async {
            let mut eof_tx = Some(client_eof_tx);
            loop {
                let message = time::timeout(Duration::from_secs(90), receiver.next())
                    .await
                    .map_err(|_| End::Idle)?;
                match message {
                    Some(Ok(Message::Binary(frame))) => match frame.first() {
                        Some(0) if eof_tx.is_some() && frame.len() <= MAX_DATA_SIZE + 1 => {
                            target_writer
                                .write_all(&frame[1..])
                                .await
                                .map_err(|_| End::Io)?;
                        }
                        Some(1) if frame.len() == 1 && eof_tx.is_some() => {
                            target_writer.shutdown().await.map_err(|_| End::Io)?;
                            if let Some(tx) = eof_tx.take() {
                                let _ = tx.send(());
                            }
                        }
                        _ => return Err(End::Protocol),
                    },
                    Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                    Some(Ok(Message::Close(_))) | None => return Err(End::Disconnected),
                    Some(Ok(Message::Text(_))) => return Err(End::Protocol),
                    Some(Err(_)) => return Err(End::Io),
                }
            }
        };

        let outbound = async {
            let mut buffer = vec![0; 16 * 1024 + 1];
            let mut heartbeat = time::interval(Duration::from_secs(25));
            heartbeat.set_missed_tick_behavior(time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    count = target_reader.read(&mut buffer[1..]) => {
                        let count = count.map_err(|_| End::Io)?;
                        if count == 0 {
                            sender.send(Message::Binary(vec![1].into())).await.map_err(|_| End::Io)?;
                            return Ok::<_, End>(());
                        }
                        buffer[0] = 0;
                        sender.send(Message::Binary(buffer[..count + 1].to_vec().into())).await.map_err(|_| End::Io)?;
                    }
                    _ = heartbeat.tick() => {
                        sender.send(Message::Ping(Vec::new().into())).await.map_err(|_| End::Io)?;
                    }
                }
            }
        };

        tokio::pin!(inbound, outbound);
        tokio::select! {
            _ = shutdown.cancelled() => Err(End::Shutdown),
            result = &mut inbound => result,
            result = &mut outbound => {
                match result {
                    Err(error) => Err(error),
                    Ok(()) => tokio::select! {
                        _ = shutdown.cancelled() => Err(End::Shutdown),
                        result = &mut inbound => result,
                        _ = client_eof_rx => Ok(()),
                    }
                }
            }
        }
    };

    let (code, reason) = match outcome {
        Ok(()) => (1000, "both TCP directions closed"),
        Err(End::Disconnected) => {
            let _ = time::timeout(Duration::from_secs(1), sender.close()).await;
            return;
        }
        Err(End::Protocol) => (1002, "invalid tunnel frame"),
        Err(End::Io) => (1011, "tunnel I/O failed"),
        Err(End::Idle) => (1001, "heartbeat timeout"),
        Err(End::Shutdown) => (1001, "server shutting down"),
    };
    tracing::debug!(code, reason, "tunnel closed");
    // Bound the close write: a stalled peer must not delay server shutdown.
    let _ = time::timeout(
        Duration::from_secs(1),
        sender.send(Message::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        }))),
    )
    .await;
}
