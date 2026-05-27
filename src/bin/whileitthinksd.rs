use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Context;
use axum::extract::State;
use axum::routing::{get, post};
use axum::{Json, Router};
use clap::Parser;
use serde_json::json;
use tokio::io::AsyncReadExt;
use tokio::net::{UnixListener, UnixStream};
use whileitthinks::daemon::{EventRuntime, RuntimeResult, SharedRuntime};
use whileitthinks::event::WhileItThinksEvent;
use whileitthinks::paths::{actions_log_path, database_path, socket_path, HTTP_ADDR};
use whileitthinks::storage::EventStore;

#[derive(Debug, Parser)]
#[command(name = "whileitthinksd")]
#[command(about = "Local WhileItThinks event daemon")]
struct Args {
    #[arg(long)]
    database: Option<PathBuf>,
    #[arg(long)]
    socket: Option<PathBuf>,
    #[arg(long, default_value = HTTP_ADDR)]
    http: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let db_path = args.database.unwrap_or_else(database_path);
    let socket = args.socket.unwrap_or_else(socket_path);
    let store = EventStore::open(&db_path)?;
    let runtime = Arc::new(tokio::sync::Mutex::new(EventRuntime::new(store)));

    let uds_runtime = runtime.clone();
    let uds_socket = socket.clone();
    let uds_task = tokio::spawn(async move { run_unix_server(uds_socket, uds_runtime).await });

    let http_runtime = runtime.clone();
    let http_addr: SocketAddr = args.http.parse().context("parse http bind address")?;
    let http_task = tokio::spawn(async move { run_http_server(http_addr, http_runtime).await });

    println!(
        "whileitthinksd listening on {} and http://{}/v1/events",
        socket.display(),
        http_addr
    );

    tokio::select! {
        result = uds_task => result??,
        result = http_task => result??,
        _ = tokio::signal::ctrl_c() => {
            println!("whileitthinksd shutting down");
        }
    }
    Ok(())
}

async fn run_http_server(addr: SocketAddr, runtime: SharedRuntime) -> anyhow::Result<()> {
    let router = Router::new()
        .route("/health", get(|| async { Json(json!({ "ok": true })) }))
        .route("/v1/events", post(handle_http_event))
        .with_state(runtime);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, router).await?;
    Ok(())
}

async fn handle_http_event(
    State(runtime): State<SharedRuntime>,
    Json(event): Json<WhileItThinksEvent>,
) -> Json<serde_json::Value> {
    let mut runtime = runtime.lock().await;
    match runtime.handle_event(event) {
        Ok(result) => {
            emit_result(&result);
            Json(json!({ "ok": true }))
        }
        Err(error) => Json(json!({ "ok": false, "error": error.to_string() })),
    }
}

async fn run_unix_server(socket: PathBuf, runtime: SharedRuntime) -> anyhow::Result<()> {
    if let Some(parent) = socket.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if socket.exists() {
        if UnixStream::connect(&socket).await.is_ok() {
            anyhow::bail!(
                "socket {} is already in use by another WhileItThinks daemon",
                socket.display()
            );
        }
        std::fs::remove_file(&socket)?;
    }
    let listener = UnixListener::bind(&socket)
        .with_context(|| format!("bind unix socket {}", socket.display()))?;

    loop {
        let (mut stream, _) = listener.accept().await?;
        let runtime = runtime.clone();
        tokio::spawn(async move {
            let mut buffer = Vec::with_capacity(4096);
            if stream.read_to_end(&mut buffer).await.is_err() {
                return;
            }
            if buffer.len() > 1_048_576 {
                return;
            }
            let Ok(event) = serde_json::from_slice::<WhileItThinksEvent>(&buffer) else {
                return;
            };
            let mut runtime = runtime.lock().await;
            if let Ok(result) = runtime.handle_event(event) {
                emit_result(&result);
            }
        });
    }
}

fn emit_result(result: &RuntimeResult) {
    let line = serde_json::to_string(result).unwrap_or_default();

    let path = actions_log_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        use std::io::Write;
        let _ = writeln!(file, "{line}");
    }

    use std::io::Write;
    let _ = writeln!(std::io::stdout(), "{line}");
}
