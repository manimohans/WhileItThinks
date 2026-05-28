use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::classifier::classify_command;
use crate::event::{EventKind, WaitState, WhileItThinksEvent};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WaitActionKind {
    None,
    Started,
    Finished,
    Permission,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WaitAction {
    pub kind: WaitActionKind,
    pub wait_state: Option<WaitState>,
    pub message: String,
}

#[derive(Debug, Default)]
pub struct WaitStateEngine {
    active: HashMap<String, ActiveWait>,
}

#[derive(Debug, Clone)]
struct ActiveWait {
    wait_state: WaitState,
    label: String,
    started_at_ms: i64,
}

impl WaitStateEngine {
    pub fn active_count(&self) -> usize {
        self.active.len()
    }

    pub fn apply(&mut self, event: &WhileItThinksEvent) -> WaitAction {
        match event.kind {
            EventKind::AgentStarted | EventKind::PromptSubmitted => {
                self.start(event, WaitState::AiGenerating, "AI is thinking")
            }
            EventKind::ToolStarted => self.start(
                event,
                WaitState::AgentRunningTools,
                event.tool_name.as_deref().unwrap_or("Tool is running"),
            ),
            EventKind::ShellStarted | EventKind::TaskStarted => {
                let classification = event
                    .command
                    .as_deref()
                    .map(classify_command)
                    .unwrap_or_else(|| classify_command("command"));
                self.start(event, classification.wait_state, &classification.summary)
            }
            EventKind::PermissionRequested => WaitAction {
                kind: WaitActionKind::Permission,
                wait_state: Some(WaitState::WaitingForPermission),
                message: format!("{} needs approval", source_label(event)),
            },
            EventKind::AgentStopped
            | EventKind::ToolFinished
            | EventKind::ToolFailed
            | EventKind::ShellFinished
            | EventKind::TaskFinished => self.finish(event),
            EventKind::FileEdited => WaitAction {
                kind: WaitActionKind::None,
                wait_state: None,
                message: "file edited".to_string(),
            },
            _ => WaitAction {
                kind: WaitActionKind::None,
                wait_state: None,
                message: "event recorded".to_string(),
            },
        }
    }

    fn start(
        &mut self,
        event: &WhileItThinksEvent,
        wait_state: WaitState,
        label: &str,
    ) -> WaitAction {
        let key = active_key(event);
        self.active.insert(
            key,
            ActiveWait {
                wait_state,
                label: label.to_string(),
                started_at_ms: event.timestamp_ms,
            },
        );
        WaitAction {
            kind: WaitActionKind::Started,
            wait_state: Some(wait_state),
            message: format!("{label} started"),
        }
    }

    fn finish(&mut self, event: &WhileItThinksEvent) -> WaitAction {
        let key = active_key(event);
        let active = self.active.remove(&key);
        match active {
            Some(active) => {
                let duration = event
                    .duration_ms
                    .unwrap_or_else(|| event.timestamp_ms.saturating_sub(active.started_at_ms));
                let result = match event.exit_code {
                    Some(code) => format!(" exited {code}"),
                    None => String::new(),
                };
                WaitAction {
                    kind: WaitActionKind::Finished,
                    wait_state: Some(active.wait_state),
                    message: format!(
                        "{} finished in {}s{}",
                        active.label,
                        duration / 1000,
                        result
                    ),
                }
            }
            None => WaitAction {
                kind: WaitActionKind::Finished,
                wait_state: Some(WaitState::ReadyForReview),
                message: format!("{} finished", source_label(event)),
            },
        }
    }
}

fn active_key(event: &WhileItThinksEvent) -> String {
    event
        .session_id
        .clone()
        .or_else(|| event.cwd.clone())
        .unwrap_or_else(|| format!("{:?}:{:?}", event.source, event.surface))
}

fn source_label(event: &WhileItThinksEvent) -> &'static str {
    match event.source {
        crate::event::Source::ClaudeCode => "Claude",
        crate::event::Source::Codex => "Codex",
        crate::event::Source::Shell => "Shell",
        crate::event::Source::Macos => "macOS",
    }
}
