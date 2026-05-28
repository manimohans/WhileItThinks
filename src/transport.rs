use std::path::Path;

use anyhow::Context;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use crate::event::WhileItThinksEvent;
use crate::paths::{http_addr, socket_path};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryChannel {
    UnixSocket,
    Http,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeliveryReport {
    pub channel: DeliveryChannel,
    pub endpoint: String,
}

pub async fn send_event(event: &WhileItThinksEvent) -> anyhow::Result<DeliveryReport> {
    let socket = socket_path();
    let http_addr = http_addr();
    send_event_to_endpoints(&socket, &http_addr, event).await
}

pub async fn send_event_to_endpoints(
    socket: &Path,
    http_addr: &str,
    event: &WhileItThinksEvent,
) -> anyhow::Result<DeliveryReport> {
    match send_event_unix(socket, event).await {
        Ok(()) => Ok(DeliveryReport {
            channel: DeliveryChannel::UnixSocket,
            endpoint: socket.display().to_string(),
        }),
        Err(unix_error) => match send_event_http_addr(http_addr, event).await {
            Ok(()) => Ok(DeliveryReport {
                channel: DeliveryChannel::Http,
                endpoint: format!("http://{http_addr}/v1/events"),
            }),
            Err(http_error) => Err(anyhow::anyhow!(
                "failed to deliver event over unix socket {} ({unix_error:#}) or HTTP {http_addr} ({http_error:#})",
                socket.display()
            )),
        },
    }
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
    send_event_http_addr(&http_addr, event).await
}

pub async fn send_event_http_addr(
    http_addr: &str,
    event: &WhileItThinksEvent,
) -> anyhow::Result<()> {
    let payload = serde_json::to_vec(event)?;
    let request = format!(
        "POST /v1/events HTTP/1.1\r\nHost: {http_addr}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        payload.len()
    );
    let mut stream = tokio::net::TcpStream::connect(http_addr)
        .await
        .with_context(|| format!("connect HTTP receiver {http_addr}"))?;
    stream.write_all(request.as_bytes()).await?;
    stream.write_all(&payload).await?;
    stream.shutdown().await?;
    let mut response = Vec::with_capacity(256);
    stream.read_to_end(&mut response).await?;
    let response = String::from_utf8_lossy(&response);
    let status = parse_http_status(&response).context("parse HTTP receiver response")?;
    if !(200..300).contains(&status) {
        anyhow::bail!("HTTP receiver returned status {status}");
    }
    Ok(())
}

fn parse_http_status(response: &str) -> Option<u16> {
    let status_line = response.lines().next()?;
    let mut parts = status_line.split_whitespace();
    let _http_version = parts.next()?;
    parts.next()?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_http_status_line() {
        assert_eq!(
            parse_http_status("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"),
            Some(200)
        );
        assert_eq!(parse_http_status("not http"), None);
    }
}
