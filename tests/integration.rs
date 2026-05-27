use std::fs;

use serde_json::Value;
use tempfile::TempDir;
use whileitthinks::classifier::classify_command;
use whileitthinks::daemon::EventRuntime;
use whileitthinks::event::{EventKind, Source, Surface, WaitState};
use whileitthinks::installer::{self, InstallOptions, Integration};
use whileitthinks::mapper::{map_hook, HookInput};
use whileitthinks::sanitize::sanitize_event;
use whileitthinks::storage::EventStore;
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
