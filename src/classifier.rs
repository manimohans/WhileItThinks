use regex::Regex;
use std::sync::OnceLock;

use crate::event::WaitState;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandClassification {
    pub wait_state: WaitState,
    pub category: &'static str,
    pub summary: String,
}

pub fn classify_command(command: &str) -> CommandClassification {
    let normalized = command.trim();
    let rules = command_rules();

    for rule in rules {
        if rule.pattern.is_match(normalized) {
            return CommandClassification {
                wait_state: rule.wait_state,
                category: rule.category,
                summary: summarize_command(normalized),
            };
        }
    }

    CommandClassification {
        wait_state: WaitState::CommandRunning,
        category: "command_running",
        summary: summarize_command(normalized),
    }
}

pub fn summarize_command(command: &str) -> String {
    let mut words = command.split_whitespace();
    let first = words.next().unwrap_or("command");
    let second = words.next();

    match second {
        Some(arg) if is_low_sensitivity_arg(arg) => format!("{first} {arg}"),
        _ => first.to_string(),
    }
}

fn is_low_sensitivity_arg(arg: &str) -> bool {
    matches!(
        arg,
        "test" | "build" | "install" | "run" | "sync" | "fetch" | "compose" | "up" | "pytest"
    ) || arg.starts_with('-')
}

struct Rule {
    category: &'static str,
    wait_state: WaitState,
    pattern: Regex,
}

fn command_rules() -> &'static [Rule] {
    static RULES: OnceLock<Vec<Rule>> = OnceLock::new();
    RULES.get_or_init(|| {
        vec![
            Rule {
                category: "test_running",
                wait_state: WaitState::TestRunning,
                pattern: Regex::new(r"\b(npm|pnpm|yarn|bun)\s+(run\s+)?test\b").unwrap(),
            },
            Rule {
                category: "test_running",
                wait_state: WaitState::TestRunning,
                pattern: Regex::new(r"\b(pytest|vitest|jest|go test|cargo test)\b").unwrap(),
            },
            Rule {
                category: "build_running",
                wait_state: WaitState::BuildRunning,
                pattern: Regex::new(r"\b(npm|pnpm|yarn|bun)\s+(run\s+)?build\b").unwrap(),
            },
            Rule {
                category: "xcode_building",
                wait_state: WaitState::XcodeBuilding,
                pattern: Regex::new(r"\bxcodebuild\b").unwrap(),
            },
            Rule {
                category: "build_running",
                wait_state: WaitState::BuildRunning,
                pattern: Regex::new(r"\b(cargo build|go build|cmake|make)\b").unwrap(),
            },
            Rule {
                category: "package_installing",
                wait_state: WaitState::PackageInstalling,
                pattern: Regex::new(
                    r"\b(npm install|pnpm install|yarn install|bun install|pip install|uv sync|cargo fetch)\b",
                )
                .unwrap(),
            },
            Rule {
                category: "docker_running",
                wait_state: WaitState::DockerRunning,
                pattern: Regex::new(r"\b(docker build|docker compose up|docker-compose up)\b")
                    .unwrap(),
            },
            Rule {
                category: "command_running",
                wait_state: WaitState::CommandRunning,
                pattern: Regex::new(r"\b(sleep|curl|gh|vercel|supabase|firebase)\b").unwrap(),
            },
        ]
    })
}
