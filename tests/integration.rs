use std::fs;
use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use whileitthinks::classifier::classify_command;
use whileitthinks::daemon::EventRuntime;
use whileitthinks::event::{EventKind, Source, Surface, WaitState};
use whileitthinks::installer::{self, InstallOptions, Integration};
use whileitthinks::mapper::{map_hook, HookInput};
use whileitthinks::sanitize::sanitize_event;
use whileitthinks::storage::EventStore;
use whileitthinks::transport::{send_event_http_addr, send_event_to_endpoints, DeliveryChannel};
use whileitthinks::wait_state::WaitActionKind;

fn fixture(path: &str) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

fn map(
    source: Source,
    event_name: &str,
    raw: Value,
) -> Vec<whileitthinks::event::WhileItThinksEvent> {
    map_hook(HookInput {
        source,
        surface: Surface::Unknown,
        event_name: event_name.to_string(),
        command: None,
        cwd: None,
        session_id: None,
        exit_code: None,
        duration_ms: None,
        raw,
    })
}

#[test]
fn claude_bash_payload_maps_to_shell_events() {
    let events = map(
        Source::ClaudeCode,
        "PreToolUse",
        fixture("fixtures/claude/pre_tool_use_bash.json"),
    );
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].kind, EventKind::ShellStarted);
    assert_eq!(
        events[0].command.as_deref(),
        Some("pytest tests/test_private_customer.py --token secret")
    );
    assert_eq!(events[0].session_id.as_deref(), Some("claude-session-1"));

    let done = map(
        Source::ClaudeCode,
        "PostToolUse",
        fixture("fixtures/claude/post_tool_use_bash_success.json"),
    );
    assert_eq!(done[0].kind, EventKind::ShellFinished);
    assert_eq!(done[0].duration_ms, Some(41000));
}

#[test]
fn claude_permission_and_stop_map_to_control_events() {
    let prompt = map(
        Source::ClaudeCode,
        "UserPromptSubmit",
        serde_json::json!({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "claude-session-1",
            "cwd": "/tmp/project",
            "prompt": "Think for a while without using tools"
        }),
    );
    assert_eq!(prompt.len(), 2);
    assert_eq!(prompt[0].kind, EventKind::PromptSubmitted);
    assert_eq!(prompt[1].kind, EventKind::AgentStarted);

    let permission = map(
        Source::ClaudeCode,
        "Notification",
        fixture("fixtures/claude/notification_permission.json"),
    );
    assert_eq!(permission[0].kind, EventKind::PermissionRequested);

    let stop = map(
        Source::ClaudeCode,
        "Stop",
        fixture("fixtures/claude/stop.json"),
    );
    assert_eq!(stop[0].kind, EventKind::AgentStopped);
}

#[test]
fn codex_payloads_map_to_shell_permission_and_stop_events() {
    let started = map(
        Source::Codex,
        "PreToolUse",
        fixture("fixtures/codex/pre_tool_use_bash.json"),
    );
    assert_eq!(started[0].kind, EventKind::ShellStarted);
    assert_eq!(
        started[0].command.as_deref(),
        Some("pnpm test -- --grep private")
    );

    let finished = map(
        Source::Codex,
        "PostToolUse",
        fixture("fixtures/codex/post_tool_use_bash.json"),
    );
    assert_eq!(finished[0].kind, EventKind::ShellFinished);
    assert_eq!(finished[0].exit_code, Some(0));

    let permission = map(
        Source::Codex,
        "PermissionRequest",
        fixture("fixtures/codex/permission_request.json"),
    );
    assert_eq!(permission[0].kind, EventKind::PermissionRequested);

    let stop = map(Source::Codex, "Stop", fixture("fixtures/codex/stop.json"));
    assert_eq!(stop[0].kind, EventKind::AgentStopped);
}

#[test]
fn sanitizer_hashes_paths_and_summarizes_commands() {
    let event = map(
        Source::ClaudeCode,
        "PreToolUse",
        fixture("fixtures/claude/pre_tool_use_bash.json"),
    )
    .remove(0);
    let sanitized = sanitize_event(&event);
    assert!(sanitized.cwd_hash.is_some());
    assert_eq!(sanitized.command_category.as_deref(), Some("test_running"));
    assert_eq!(sanitized.command_summary.as_deref(), Some("pytest"));
    let serialized = serde_json::to_string(&sanitized).unwrap();
    assert!(!serialized.contains("private_customer"));
    assert!(!serialized.contains("--token"));
    assert!(!serialized.contains("/Users/mani"));
}

#[test]
fn command_classifier_covers_core_wait_states() {
    assert_eq!(
        classify_command("pnpm test").wait_state,
        WaitState::TestRunning
    );
    assert_eq!(
        classify_command("npm run build").wait_state,
        WaitState::BuildRunning
    );
    assert_eq!(
        classify_command("uv sync").wait_state,
        WaitState::PackageInstalling
    );
    assert_eq!(
        classify_command("docker compose up").wait_state,
        WaitState::DockerRunning
    );
    assert_eq!(
        classify_command("xcodebuild -scheme App").wait_state,
        WaitState::XcodeBuilding
    );
}

#[test]
fn runtime_persists_sanitized_event_and_wait_action() {
    let store = EventStore::in_memory().unwrap();
    let mut runtime = EventRuntime::new(store);
    let event = map(
        Source::Codex,
        "PreToolUse",
        fixture("fixtures/codex/pre_tool_use_bash.json"),
    )
    .remove(0);
    let result = runtime.handle_event(event).unwrap();
    assert!(result.ok);
    assert_eq!(
        result.sanitized.command_category.as_deref(),
        Some("test_running")
    );
    assert_eq!(result.action.kind, WaitActionKind::Started);
    assert_eq!(result.action.wait_state, Some(WaitState::TestRunning));
}

#[test]
fn runtime_health_reports_storage_and_active_waits() {
    let store = EventStore::in_memory().unwrap();
    let mut runtime = EventRuntime::new(store);
    let initial = runtime.health().unwrap();
    assert!(initial.ok);
    assert_eq!(initial.storage.event_count, 0);
    assert_eq!(initial.active_wait_count, 0);

    let event = map(
        Source::ClaudeCode,
        "PreToolUse",
        fixture("fixtures/claude/pre_tool_use_bash.json"),
    )
    .remove(0);
    runtime.handle_event(event).unwrap();

    let health = runtime.health().unwrap();
    assert!(health.ok);
    assert_eq!(health.storage.event_count, 1);
    assert_eq!(health.active_wait_count, 1);
    assert!(health.storage.last_event_timestamp_ms.is_some());
}

#[test]
fn file_store_persists_sanitized_events_without_raw_sensitive_values() {
    let temp = TempDir::new().unwrap();
    let db = temp.path().join("events.sqlite3");
    let store = EventStore::open(&db).unwrap();
    let mut runtime = EventRuntime::new(store);
    let event = map(
        Source::ClaudeCode,
        "PreToolUse",
        fixture("fixtures/claude/pre_tool_use_bash.json"),
    )
    .remove(0);
    let event_id = event.id.clone();

    runtime.handle_event(event).unwrap();
    let store = EventStore::open(&db).unwrap();

    assert_eq!(store.event_count().unwrap(), 1);
    assert!(store.event_exists(&event_id).unwrap());
    assert!(store.event_payload_contains("pytest").unwrap());
    assert!(!store.event_payload_contains("private_customer").unwrap());
    assert!(!store.event_payload_contains("--token").unwrap());
    assert!(!store.event_payload_contains("/Users/mani").unwrap());
}

#[test]
fn runtime_tracks_non_tool_ai_generation_waits() {
    let store = EventStore::in_memory().unwrap();
    let mut runtime = EventRuntime::new(store);
    let mut events = map(
        Source::ClaudeCode,
        "UserPromptSubmit",
        serde_json::json!({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "claude-session-2",
            "cwd": "/tmp/project",
            "prompt": "Explain the architecture without tools"
        }),
    );

    let started = runtime.handle_event(events.remove(0)).unwrap();
    assert_eq!(started.action.kind, WaitActionKind::Started);
    assert_eq!(started.action.wait_state, Some(WaitState::AiGenerating));

    let stopped = runtime
        .handle_event(
            map(
                Source::ClaudeCode,
                "Stop",
                serde_json::json!({
                    "hook_event_name": "Stop",
                    "session_id": "claude-session-2",
                    "cwd": "/tmp/project"
                }),
            )
            .remove(0),
        )
        .unwrap();
    assert_eq!(stopped.action.kind, WaitActionKind::Finished);
    assert_eq!(stopped.action.wait_state, Some(WaitState::AiGenerating));
}

#[test]
fn installer_merges_claude_hooks_idempotently_and_uninstalls() {
    let temp = TempDir::new().unwrap();
    let home = temp.path();
    let claude_dir = home.join(".claude");
    fs::create_dir_all(&claude_dir).unwrap();
    fs::write(
        claude_dir.join("settings.json"),
        r#"{"statusLine":{"type":"command","command":"existing"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo existing"}]}]}}"#,
    )
    .unwrap();

    let options = InstallOptions {
        home: home.to_path_buf(),
        hook_path: "/tmp/whileitthinks-hook".to_string(),
    };
    installer::install(Integration::Claude, &options).unwrap();
    installer::install(Integration::Claude, &options).unwrap();

    let value: Value =
        serde_json::from_str(&fs::read_to_string(claude_dir.join("settings.json")).unwrap())
            .unwrap();
    assert_eq!(value["statusLine"]["command"], "existing");
    let serialized = serde_json::to_string(&value).unwrap();
    assert_eq!(
        serialized
            .matches("--source claude-code --event Stop")
            .count(),
        1
    );
    assert!(serialized.contains("--source claude-code --event PermissionRequest"));
    assert!(serialized.contains("\"timeout\":5"));
    assert!(fs::read_dir(&claude_dir).unwrap().any(|entry| entry
        .unwrap()
        .file_name()
        .to_string_lossy()
        .contains("whileitthinks-backup")));

    installer::uninstall(Integration::Claude, &options).unwrap();
    let value: Value =
        serde_json::from_str(&fs::read_to_string(claude_dir.join("settings.json")).unwrap())
            .unwrap();
    let serialized = serde_json::to_string(&value).unwrap();
    assert!(serialized.contains("echo existing"));
    assert!(!serialized.contains("whileitthinks-hook"));
}

#[test]
fn installer_creates_codex_hooks_and_reports_status() {
    let temp = TempDir::new().unwrap();
    let options = InstallOptions {
        home: temp.path().to_path_buf(),
        hook_path: "/tmp/whileitthinks-hook".to_string(),
    };
    fs::write(&options.hook_path, "").unwrap();

    installer::install(Integration::Codex, &options).unwrap();
    let status = installer::status_with_options(Integration::Codex, &options).unwrap();
    assert!(status.installed);
    assert!(status.configured);
    assert_eq!(status.installed_hook_count, status.expected_hook_count);
    assert!(status.note.contains("/hooks"));

    let value: Value = serde_json::from_str(
        &fs::read_to_string(temp.path().join(".codex").join("hooks.json")).unwrap(),
    )
    .unwrap();
    let serialized = serde_json::to_string(&value).unwrap();
    assert!(serialized.contains("--source codex --event PreToolUse"));
    assert!(serialized.contains("--source codex --event PermissionRequest"));
    assert!(serialized.contains("WhileItThinks"));
    let permission_groups = value["hooks"]["PermissionRequest"].as_array().unwrap();
    assert!(permission_groups
        .iter()
        .any(|group| group.get("matcher").is_none()));
}

#[test]
fn status_reports_stale_hook_paths() {
    let temp = TempDir::new().unwrap();
    let old_hook = temp.path().join("old").join("whileitthinks-hook");
    fs::create_dir_all(old_hook.parent().unwrap()).unwrap();
    fs::write(&old_hook, "").unwrap();
    let new_hook = temp.path().join("new").join("whileitthinks-hook");
    fs::create_dir_all(new_hook.parent().unwrap()).unwrap();
    fs::write(&new_hook, "").unwrap();

    let install_options = InstallOptions {
        home: temp.path().to_path_buf(),
        hook_path: old_hook.to_string_lossy().to_string(),
    };
    installer::install(Integration::Claude, &install_options).unwrap();

    let current_options = InstallOptions {
        home: temp.path().to_path_buf(),
        hook_path: new_hook.to_string_lossy().to_string(),
    };
    let status = installer::status_with_options(Integration::Claude, &current_options).unwrap();
    assert!(status.installed);
    assert!(!status.configured);
    assert_eq!(
        status.stale_hook_paths,
        vec![old_hook.to_string_lossy().to_string()]
    );
    assert!(status.note.contains("another app copy"));
}

#[test]
fn shell_installer_creates_idempotent_zsh_fallback_and_uninstalls() {
    let temp = TempDir::new().unwrap();
    let zshrc = temp.path().join(".zshrc");
    fs::write(&zshrc, "export EXISTING=1\n").unwrap();
    let hook = temp
        .path()
        .join("WhileItThinks.app/Contents/MacOS/whileitthinks-hook");
    fs::create_dir_all(hook.parent().unwrap()).unwrap();
    fs::write(&hook, "").unwrap();
    let options = InstallOptions {
        home: temp.path().to_path_buf(),
        hook_path: hook.to_string_lossy().to_string(),
    };

    installer::install(Integration::Shell, &options).unwrap();
    installer::install(Integration::Shell, &options).unwrap();
    let status = installer::status_with_options(Integration::Shell, &options).unwrap();
    assert!(status.installed);
    assert!(status.configured);
    assert_eq!(status.installed_hook_count, 1);

    let zshrc_contents = fs::read_to_string(&zshrc).unwrap();
    assert_eq!(
        zshrc_contents
            .matches("# >>> whileitthinks shell integration >>>")
            .count(),
        1
    );
    assert!(zshrc_contents.contains("export EXISTING=1"));

    let source_path = temp
        .path()
        .join("Library/Application Support/WhileItThinks/shell/zsh.zsh");
    let source = fs::read_to_string(&source_path).unwrap();
    assert!(source.contains("--source shell"));
    assert!(source.contains("--command-stdin"));
    assert!(source.contains("--session-id"));

    assert!(fs::read_dir(temp.path()).unwrap().any(|entry| entry
        .unwrap()
        .file_name()
        .to_string_lossy()
        .contains("whileitthinks-backup")));

    installer::uninstall(Integration::Shell, &options).unwrap();
    let zshrc_contents = fs::read_to_string(&zshrc).unwrap();
    assert!(zshrc_contents.contains("export EXISTING=1"));
    assert!(!zshrc_contents.contains("whileitthinks shell integration"));
    assert!(!source_path.exists());
}

#[test]
fn shell_installer_does_not_remove_unmatched_marker_content() {
    let temp = TempDir::new().unwrap();
    let zshrc = temp.path().join(".zshrc");
    fs::write(
        &zshrc,
        "export BEFORE=1\n# >>> whileitthinks shell integration >>>\nexport AFTER=1\n",
    )
    .unwrap();
    let hook = temp.path().join("whileitthinks-hook");
    fs::write(&hook, "").unwrap();
    let options = InstallOptions {
        home: temp.path().to_path_buf(),
        hook_path: hook.to_string_lossy().to_string(),
    };

    installer::install(Integration::Shell, &options).unwrap();
    let contents = fs::read_to_string(&zshrc).unwrap();
    assert!(contents.contains("export BEFORE=1"));
    assert!(contents.contains("export AFTER=1"));
    assert!(contents.contains("# >>> whileitthinks shell integration >>>"));
    assert!(contents.contains("# <<< whileitthinks shell integration <<<"));
}

#[test]
fn shell_status_reports_stale_hook_path() {
    let temp = TempDir::new().unwrap();
    let old_hook = temp.path().join("old/whileitthinks-hook");
    fs::create_dir_all(old_hook.parent().unwrap()).unwrap();
    fs::write(&old_hook, "").unwrap();
    let new_hook = temp.path().join("new/whileitthinks-hook");
    fs::create_dir_all(new_hook.parent().unwrap()).unwrap();
    fs::write(&new_hook, "").unwrap();

    let install_options = InstallOptions {
        home: temp.path().to_path_buf(),
        hook_path: old_hook.to_string_lossy().to_string(),
    };
    installer::install(Integration::Shell, &install_options).unwrap();

    let current_options = InstallOptions {
        home: temp.path().to_path_buf(),
        hook_path: new_hook.to_string_lossy().to_string(),
    };
    let status = installer::status_with_options(Integration::Shell, &current_options).unwrap();
    assert!(status.installed);
    assert!(!status.configured);
    assert_eq!(
        status.stale_hook_paths,
        vec![old_hook.to_string_lossy().to_string()]
    );
}

#[test]
fn shell_events_correlate_by_session_id() {
    let store = EventStore::in_memory().unwrap();
    let mut runtime = EventRuntime::new(store);
    let start = map_hook(HookInput {
        source: Source::Shell,
        surface: Surface::Cli,
        event_name: "shell_started".to_string(),
        command: Some("sleep 12".to_string()),
        cwd: Some("/tmp/project".to_string()),
        session_id: Some("shell-session-1".to_string()),
        exit_code: None,
        duration_ms: None,
        raw: serde_json::json!({}),
    })
    .remove(0);
    let started = runtime.handle_event(start).unwrap();
    assert_eq!(started.action.kind, WaitActionKind::Started);
    assert_eq!(started.action.wait_state, Some(WaitState::CommandRunning));

    let finish = map_hook(HookInput {
        source: Source::Shell,
        surface: Surface::Cli,
        event_name: "shell_finished".to_string(),
        command: Some("sleep 12".to_string()),
        cwd: Some("/tmp/project".to_string()),
        session_id: Some("shell-session-1".to_string()),
        exit_code: Some(0),
        duration_ms: Some(12_000),
        raw: serde_json::json!({}),
    })
    .remove(0);
    let finished = runtime.handle_event(finish).unwrap();
    assert_eq!(finished.action.kind, WaitActionKind::Finished);
    assert_eq!(finished.action.wait_state, Some(WaitState::CommandRunning));
    assert!(finished.action.message.contains("finished in 12s"));
}

#[tokio::test]
async fn delivery_falls_back_to_http_when_unix_socket_is_absent() {
    let temp = TempDir::new().unwrap();
    let missing_socket = temp.path().join("missing.sock");
    let (addr, server) = one_shot_http_response("200 OK", r#"{"ok":true}"#).await;
    let event = map_hook(HookInput {
        source: Source::Codex,
        surface: Surface::Cli,
        event_name: "PreToolUse".to_string(),
        command: Some("pnpm test".to_string()),
        cwd: Some("/tmp/project".to_string()),
        session_id: Some("transport-fallback".to_string()),
        exit_code: None,
        duration_ms: None,
        raw: serde_json::json!({"tool_name": "Bash"}),
    })
    .remove(0);

    let report = send_event_to_endpoints(&missing_socket, &addr, &event)
        .await
        .unwrap();

    assert_eq!(report.channel, DeliveryChannel::Http);
    assert!(report.endpoint.ends_with("/v1/events"));
    server.await.unwrap();
}

#[tokio::test]
async fn http_delivery_rejects_non_success_response() {
    let (addr, server) =
        one_shot_http_response("500 Internal Server Error", r#"{"ok":false}"#).await;
    let event = map_hook(HookInput {
        source: Source::Shell,
        surface: Surface::Cli,
        event_name: "shell_started".to_string(),
        command: Some("sleep 12".to_string()),
        cwd: Some("/tmp/project".to_string()),
        session_id: Some("transport-500".to_string()),
        exit_code: None,
        duration_ms: None,
        raw: serde_json::json!({}),
    })
    .remove(0);

    let error = send_event_http_addr(&addr, &event).await.unwrap_err();

    assert!(error.to_string().contains("500"));
    server.await.unwrap();
}

#[test]
fn hook_binary_accepts_command_stdin_for_shell_events() {
    let bin = std::env::var("CARGO_BIN_EXE_whileitthinks-hook")
        .unwrap_or_else(|_| "target/debug/whileitthinks-hook".to_string());
    let mut child = Command::new(bin)
        .args([
            "--source",
            "shell",
            "--surface",
            "cli",
            "--event",
            "shell_started",
            "--cwd",
            "/tmp/project",
            "--session-id",
            "shell-session-stdin",
            "--command-stdin",
            "--print",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"pytest tests/private.py --token secret")
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let events: Vec<whileitthinks::event::WhileItThinksEvent> =
        serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(events[0].source, Source::Shell);
    assert_eq!(events[0].kind, EventKind::ShellStarted);
    assert_eq!(events[0].session_id.as_deref(), Some("shell-session-stdin"));
    assert_eq!(
        events[0].command.as_deref(),
        Some("pytest tests/private.py --token secret")
    );
}

#[test]
fn hook_binary_fails_open_when_receiver_is_unavailable() {
    let temp = TempDir::new().unwrap();
    let bin = bin_path("whileitthinks-hook");
    let unavailable_http_addr = free_loopback_addr();
    let mut child = Command::new(bin)
        .args([
            "--source",
            "shell",
            "--surface",
            "cli",
            "--event",
            "shell_started",
            "--cwd",
            "/tmp/project",
            "--session-id",
            "shell-session-no-daemon",
            "--command-stdin",
            "--verbose",
        ])
        .env("WHILEITTHINKS_SOCKET", temp.path().join("missing.sock"))
        .env("WHILEITTHINKS_HTTP_ADDR", unavailable_http_addr)
        .stdin(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"sleep 12")
        .unwrap();
    let output = child.wait_with_output().unwrap();

    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("send failed"));
}

#[test]
fn daemon_smoke_commands_persist_claude_codex_and_shell_events() {
    let temp = TempDir::new().unwrap();
    let db = temp.path().join("events.sqlite3");
    let socket = temp.path().join("whileitthinks.sock");
    let http_addr = free_loopback_addr();
    let daemon_bin = bin_path("whileitthinksd");
    let cli_bin = bin_path("whileitthinks");
    let mut daemon = Command::new(&daemon_bin)
        .args([
            "--database",
            db.to_str().unwrap(),
            "--socket",
            socket.to_str().unwrap(),
            "--http",
            &http_addr,
        ])
        .env("HOME", temp.path())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    wait_for_receiver(&socket, &http_addr);

    for (source, event, command) in [
        (
            "claude-code",
            "shell_started",
            "pytest tests/private_customer.py --token secret",
        ),
        ("codex", "shell_started", "pnpm test -- --grep private"),
        ("shell", "shell_started", "sleep 12"),
    ] {
        let output = Command::new(&cli_bin)
            .args([
                "test-event",
                "--source",
                source,
                "--event",
                event,
                "--command",
                command,
            ])
            .env("HOME", temp.path())
            .env("WHILEITTHINKS_SOCKET", &socket)
            .env("WHILEITTHINKS_HTTP_ADDR", &http_addr)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "test-event failed for {source}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("\"delivered\""));
    }

    wait_for_event_count(&db, 3);
    let store = EventStore::open(&db).unwrap();
    assert_eq!(store.event_count().unwrap(), 3);
    assert_eq!(
        store
            .event_count_by_source(&serde_json::to_string(&Source::ClaudeCode).unwrap())
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .event_count_by_source(&serde_json::to_string(&Source::Codex).unwrap())
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .event_count_by_source(&serde_json::to_string(&Source::Shell).unwrap())
            .unwrap(),
        1
    );
    assert!(store.event_payload_contains("pytest").unwrap());
    assert!(!store.event_payload_contains("private_customer").unwrap());
    assert!(!store.event_payload_contains("--token").unwrap());

    let health = get_health(&http_addr);
    assert!(health.contains("\"ok\":true"));
    assert!(health.contains("\"event_count\":3"));

    daemon.kill().unwrap();
    daemon.wait().unwrap();
}

async fn one_shot_http_response(
    status: &'static str,
    body: &'static str,
) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut buffer = [0_u8; 2048];
        let _ = stream.read(&mut buffer).await.unwrap();
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).await.unwrap();
        stream.shutdown().await.unwrap();
    });
    (addr, server)
}

fn bin_path(name: &str) -> String {
    std::env::var(format!("CARGO_BIN_EXE_{name}"))
        .unwrap_or_else(|_| format!("target/debug/{name}"))
}

fn free_loopback_addr() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    drop(listener);
    addr
}

fn wait_for_receiver(socket: &Path, http_addr: &str) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if socket.exists() && get_health_maybe(http_addr).is_some() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("receiver did not become healthy at {http_addr}");
}

fn wait_for_event_count(db: &Path, expected: i64) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if db.exists() {
            if let Ok(store) = EventStore::open(db) {
                if store.event_count().unwrap_or_default() >= expected {
                    return;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let count = EventStore::open(db)
        .and_then(|store| store.event_count())
        .unwrap_or_default();
    panic!("expected at least {expected} events, found {count}");
}

fn get_health(http_addr: &str) -> String {
    get_health_maybe(http_addr).unwrap_or_else(|| panic!("health check failed at {http_addr}"))
}

fn get_health_maybe(http_addr: &str) -> Option<String> {
    let mut stream = TcpStream::connect(http_addr).ok()?;
    stream
        .set_read_timeout(Some(Duration::from_millis(250)))
        .ok()?;
    stream
        .set_write_timeout(Some(Duration::from_millis(250)))
        .ok()?;
    write!(
        stream,
        "GET /health HTTP/1.1\r\nHost: {http_addr}\r\nConnection: close\r\n\r\n"
    )
    .ok()?;
    let mut response = String::new();
    std::io::Read::read_to_string(&mut stream, &mut response).ok()?;
    if response.starts_with("HTTP/1.1 200") {
        Some(response)
    } else {
        None
    }
}
