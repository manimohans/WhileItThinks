use serde_json::Value;

use crate::event::{EventKind, Source, Surface, WhileItThinksEvent};

#[derive(Debug, Clone)]
pub struct HookInput {
    pub source: Source,
    pub surface: Surface,
    pub event_name: String,
    pub command: Option<String>,
    pub cwd: Option<String>,
    pub session_id: Option<String>,
    pub exit_code: Option<i32>,
    pub duration_ms: Option<i64>,
    pub raw: Value,
}

pub fn map_hook(input: HookInput) -> Vec<WhileItThinksEvent> {
    match input.source {
        Source::ClaudeCode => map_claude(input),
        Source::Codex => map_codex(input),
        Source::Shell | Source::Macos => map_fallback(input),
    }
}

fn map_claude(input: HookInput) -> Vec<WhileItThinksEvent> {
    let event_name = raw_event_name(&input);
    match event_name.as_str() {
        "SessionStart" => vec![base(&input, EventKind::SessionStarted)],
        "UserPromptSubmit" => vec![
            base(&input, EventKind::PromptSubmitted),
            base(&input, EventKind::AgentStarted),
        ],
        "PreToolUse" => {
            let tool_name = string_at(&input.raw, &["tool_name"]);
            if tool_name.as_deref() == Some("Bash") {
                vec![shell_event(&input, EventKind::ShellStarted)]
            } else {
                vec![tool_event(&input, EventKind::ToolStarted, tool_name)]
            }
        }
        "PostToolUse" => {
            let tool_name = string_at(&input.raw, &["tool_name"]);
            if tool_name.as_deref() == Some("Bash") {
                vec![shell_event(&input, EventKind::ShellFinished)]
            } else if matches!(tool_name.as_deref(), Some("Edit" | "Write" | "MultiEdit")) {
                vec![tool_event(&input, EventKind::FileEdited, tool_name)]
            } else {
                vec![tool_event(&input, EventKind::ToolFinished, tool_name)]
            }
        }
        "PostToolUseFailure" => vec![tool_event(
            &input,
            EventKind::ToolFailed,
            string_at(&input.raw, &["tool_name"]),
        )],
        "Notification" | "PermissionRequest" => {
            let notification_type = string_at(&input.raw, &["notification_type"])
                .or_else(|| string_at(&input.raw, &["type"]));
            if notification_type
                .as_deref()
                .map(|kind| kind.contains("permission"))
                .unwrap_or(true)
            {
                vec![base(&input, EventKind::PermissionRequested)]
            } else {
                vec![base(&input, EventKind::AgentThought)]
            }
        }
        "Stop" => vec![base(&input, EventKind::AgentStopped)],
        _ => vec![],
    }
}

fn map_codex(input: HookInput) -> Vec<WhileItThinksEvent> {
    let event_name = raw_event_name(&input);
    match event_name.as_str() {
        "SessionStart" => vec![base(&input, EventKind::SessionStarted)],
        "UserPromptSubmit" => vec![
            base(&input, EventKind::PromptSubmitted),
            base(&input, EventKind::AgentStarted),
        ],
        "PreToolUse" => {
            let tool_name = tool_name(&input.raw);
            if is_bash_tool(tool_name.as_deref()) {
                vec![shell_event(&input, EventKind::ShellStarted)]
            } else {
                vec![tool_event(&input, EventKind::ToolStarted, tool_name)]
            }
        }
        "PostToolUse" => {
            let tool_name = tool_name(&input.raw);
            if is_bash_tool(tool_name.as_deref()) {
                vec![shell_event(&input, EventKind::ShellFinished)]
            } else if is_file_tool(tool_name.as_deref()) {
                vec![tool_event(&input, EventKind::FileEdited, tool_name)]
            } else {
                vec![tool_event(&input, EventKind::ToolFinished, tool_name)]
            }
        }
        "PermissionRequest" => vec![base(&input, EventKind::PermissionRequested)],
        "Stop" => vec![base(&input, EventKind::AgentStopped)],
        _ => vec![],
    }
}

fn map_fallback(input: HookInput) -> Vec<WhileItThinksEvent> {
    let kind = match input.event_name.as_str() {
        "shell_started" => EventKind::ShellStarted,
        "shell_finished" => EventKind::ShellFinished,
        "active_app_changed" => EventKind::ActiveAppChanged,
        _ => EventKind::ToolStarted,
    };
    vec![shell_event(&input, kind)]
}

fn base(input: &HookInput, kind: EventKind) -> WhileItThinksEvent {
    let mut event = WhileItThinksEvent::new(input.source, input.surface, kind)
        .with_raw_event_name(raw_event_name(input));
    event.cwd = input
        .cwd
        .clone()
        .or_else(|| string_at(&input.raw, &["cwd"]));
    event.project_root = string_at(&input.raw, &["project_root"])
        .or_else(|| string_at(&input.raw, &["workspace_root"]));
    event.session_id = input
        .session_id
        .clone()
        .or_else(|| string_at(&input.raw, &["session_id"]));
    event.conversation_id = string_at(&input.raw, &["conversation_id"]);
    event.generation_id = string_at(&input.raw, &["generation_id"]);
    event.duration_ms = input
        .duration_ms
        .or_else(|| int_at(&input.raw, &["duration_ms"]))
        .or_else(|| int_at(&input.raw, &["duration"]));
    event.exit_code = input
        .exit_code
        .or_else(|| int_at(&input.raw, &["exit_code"]).and_then(|code| i32::try_from(code).ok()));
    event
}

fn shell_event(input: &HookInput, kind: EventKind) -> WhileItThinksEvent {
    let mut event = base(input, kind);
    event.command = input
        .command
        .clone()
        .or_else(|| string_at(&input.raw, &["tool_input", "command"]))
        .or_else(|| string_at(&input.raw, &["input", "command"]))
        .or_else(|| string_at(&input.raw, &["command"]))
        .or_else(|| string_at(&input.raw, &["command_text"]))
        .or_else(|| string_at(&input.raw, &["text"]));
    event.tool_name = tool_name(&input.raw);
    event
}

fn tool_event(input: &HookInput, kind: EventKind, tool_name: Option<String>) -> WhileItThinksEvent {
    let mut event = base(input, kind);
    event.tool_name = tool_name;
    event.command = input
        .command
        .clone()
        .or_else(|| string_at(&input.raw, &["tool_input", "command"]))
        .or_else(|| string_at(&input.raw, &["input", "command"]));
    event
}

fn raw_event_name(input: &HookInput) -> String {
    string_at(&input.raw, &["hook_event_name"])
        .or_else(|| string_at(&input.raw, &["event_name"]))
        .unwrap_or_else(|| input.event_name.clone())
}

fn tool_name(raw: &Value) -> Option<String> {
    string_at(raw, &["tool_name"])
        .or_else(|| string_at(raw, &["tool"]))
        .or_else(|| string_at(raw, &["tool_call", "name"]))
}

fn is_bash_tool(tool_name: Option<&str>) -> bool {
    matches!(tool_name, Some("Bash" | "bash" | "shell" | "Shell"))
}

fn is_file_tool(tool_name: Option<&str>) -> bool {
    matches!(
        tool_name,
        Some("apply_patch" | "Edit" | "Write" | "MultiEdit" | "edit" | "write")
    )
}

fn string_at(raw: &Value, path: &[&str]) -> Option<String> {
    let mut current = raw;
    for key in path {
        current = current.get(*key)?;
    }
    current.as_str().map(ToOwned::to_owned)
}

fn int_at(raw: &Value, path: &[&str]) -> Option<i64> {
    let mut current = raw;
    for key in path {
        current = current.get(*key)?;
    }
    current.as_i64()
}
