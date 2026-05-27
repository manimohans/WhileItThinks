use std::path::Path;

use anyhow::Context;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;

use crate::event::WhileItThinksEvent;
use crate::paths::{http_addr, socket_path};

pub async fn send_event(event: &WhileItThinksEvent) -> anyhow::Result<()> {
    let socket = socket_path();
    if send_event_unix(&socket, event).await.is_ok() {
        return Ok(());
    }
    send_event_http(event).await
}

pub async fn send_event_unix(path: &Path, event: &WhileItThinksEvent) -> anyhow::Result<()> {
    let mut stream = UnixStream::connect(path)
        .await
        .with_context(|| format!("connect unix socket {}", path.display()))?;
    let payload = serde_json::to_vec(event)?;
    stream.write_all(&payload).await?;
    stream.shutdown().await?;
    Ok(())
}

pub async fn send_event_http(event: &WhileItThinksEvent) -> anyhow::Result<()> {
    let http_addr = http_addr();
    let payload = serde_json::to_vec(event)?;
    let request = format!(
        "POST /v1/events HTTP/1.1\r\nHost: {http_addr}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        payload.len()
    );
    let mut stream = tokio::net::TcpStream::connect(http_addr).await?;
    stream.write_all(request.as_bytes()).await?;
    stream.write_all(&payload).await?;
    stream.shutdown().await?;
    Ok(())
}
