use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};
use whileitthinks::event::{Source, Surface};
use whileitthinks::installer::{self, InstallOptions, Integration};
use whileitthinks::mapper::{map_hook, HookInput};
use whileitthinks::onboarding::DESKTOP_APP_GUIDE;
use whileitthinks::paths::home_dir;
use whileitthinks::transport::send_event;

#[derive(Debug, Parser)]
#[command(name = "whileitthinks")]
#[command(about = "Installer and diagnostics CLI for WhileItThinks")]
struct Args {
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    hook_path: Option<String>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Status,
    Guide,
    Install {
        target: Target,
    },
    Uninstall {
        target: Target,
    },
    TestEvent {
        #[arg(long, value_enum, default_value = "claude-code")]
        source: SourceArg,
        #[arg(long, default_value = "PreToolUse")]
        event: String,
        #[arg(long, default_value = "sleep 8")]
        command: String,
    },
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum Target {
    All,
    Claude,
    Codex,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum SourceArg {
    #[value(name = "claude-code")]
    ClaudeCode,
    Codex,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let home = args.home.unwrap_or_else(home_dir);
    let hook_path = args.hook_path.unwrap_or_else(installer::discover_hook_path);
    let options = InstallOptions {
        home: home.clone(),
        hook_path,
    };

    match args.command {
        Command::Status => {
            let statuses: Vec<_> = integrations(Target::All)
                .into_iter()
                .map(|integration| installer::status_with_options(integration, &options))
                .collect::<anyhow::Result<Vec<_>>>()?;
            println!("{}", serde_json::to_string_pretty(&statuses)?);
        }
        Command::Guide => {
            println!("{DESKTOP_APP_GUIDE}");
        }
        Command::Install { target } => {
            for integration in integrations(target) {
                let report = installer::install(integration, &options)?;
                println!("{}", serde_json::to_string_pretty(&report)?);
            }
            if matches!(target, Target::All | Target::Codex) {
                println!("Codex trust step: open Terminal, run codex, type /hooks in the Codex CLI, and approve WhileItThinks. Codex Desktop does not currently expose /hooks in chat.");
            }
        }
        Command::Uninstall { target } => {
            for integration in integrations(target) {
                let report = installer::uninstall(integration, &options)?;
                println!("{}", serde_json::to_string_pretty(&report)?);
            }
        }
        Command::TestEvent {
            source,
            event,
            command,
        } => {
            let source = source.into();
            let event = normalize_test_event(source, &event);
            let raw = serde_json::json!({
                "hook_event_name": event,
                "tool_name": "Bash",
                "tool_input": { "command": command },
                "cwd": std::env::current_dir()?.to_string_lossy(),
            });
            let events = map_hook(HookInput {
                source,
                surface: Surface::Unknown,
                event_name: event,
                command: None,
                cwd: None,
                exit_code: None,
                duration_ms: None,
                raw,
            });
            if events.is_empty() {
                eprintln!(
                    "No WhileItThinks event was produced for this synthetic hook. For Claude/Codex shell tests, use shell_started, shell_finished, PreToolUse, or PostToolUse."
                );
            }
            for event in events {
                send_event(&event).await.ok();
                println!("{}", serde_json::to_string_pretty(&event)?);
            }
        }
    }
    Ok(())
}

fn normalize_test_event(source: Source, event: &str) -> String {
    match source {
        Source::ClaudeCode | Source::Codex => match event {
            "shell_started" | "tool_started" => "PreToolUse".to_string(),
            "shell_finished" | "tool_finished" => "PostToolUse".to_string(),
            "permission_requested" => "PermissionRequest".to_string(),
            "agent_started" | "prompt_submitted" => "UserPromptSubmit".to_string(),
            "agent_stopped" => "Stop".to_string(),
            _ => event.to_string(),
        },
        Source::Shell | Source::Macos => event.to_string(),
    }
}

fn integrations(target: Target) -> Vec<Integration> {
    match target {
        Target::All => vec![Integration::Claude, Integration::Codex],
        Target::Claude => vec![Integration::Claude],
        Target::Codex => vec![Integration::Codex],
    }
}

impl From<SourceArg> for Source {
    fn from(value: SourceArg) -> Self {
        match value {
            SourceArg::ClaudeCode => Source::ClaudeCode,
            SourceArg::Codex => Source::Codex,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_event_aliases_match_claude_and_codex_hook_names() {
        assert_eq!(
            normalize_test_event(Source::ClaudeCode, "shell_started"),
            "PreToolUse"
        );
        assert_eq!(
            normalize_test_event(Source::Codex, "shell_finished"),
            "PostToolUse"
        );
        assert_eq!(
            normalize_test_event(Source::ClaudeCode, "permission_requested"),
            "PermissionRequest"
        );
    }
}
