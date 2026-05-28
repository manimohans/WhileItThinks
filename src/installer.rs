use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use uuid::Uuid;

use crate::event::Source;
use crate::paths::{default_installed_hook_path, home_dir};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Integration {
    Claude,
    Codex,
    Shell,
}

impl fmt::Display for Integration {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Claude => write!(f, "Claude Code"),
            Self::Codex => write!(f, "Codex"),
            Self::Shell => write!(f, "Shell"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct InstallOptions {
    pub home: PathBuf,
    pub hook_path: String,
}

impl Default for InstallOptions {
    fn default() -> Self {
        Self {
            home: home_dir(),
            hook_path: discover_hook_path(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IntegrationStatus {
    pub integration: Integration,
    pub config_path: PathBuf,
    pub config_exists: bool,
    pub installed: bool,
    pub configured: bool,
    pub installed_hook_count: usize,
    pub expected_hook_count: usize,
    pub expected_hook_path: String,
    pub expected_hook_path_exists: bool,
    pub stale_hook_paths: Vec<String>,
    pub missing_events: Vec<String>,
    pub requires_user_action: bool,
    pub note: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InstallReport {
    pub integration: Integration,
    pub config_path: PathBuf,
    pub backup_path: Option<PathBuf>,
    pub installed: bool,
    pub note: String,
}

pub fn install(
    integration: Integration,
    options: &InstallOptions,
) -> anyhow::Result<InstallReport> {
    match integration {
        Integration::Claude => install_claude(options),
        Integration::Codex => install_codex(options),
        Integration::Shell => install_shell(options),
    }
}

pub fn uninstall(
    integration: Integration,
    options: &InstallOptions,
) -> anyhow::Result<InstallReport> {
    match integration {
        Integration::Claude => uninstall_integration(
            integration,
            &claude_config_path(&options.home),
            Source::ClaudeCode,
        ),
        Integration::Codex => uninstall_integration(
            integration,
            &codex_config_path(&options.home),
            Source::Codex,
        ),
        Integration::Shell => uninstall_shell(options),
    }
}

pub fn status(integration: Integration, home: &Path) -> anyhow::Result<IntegrationStatus> {
    let options = InstallOptions {
        home: home.to_path_buf(),
        hook_path: discover_hook_path(),
    };
    status_with_options(integration, &options)
}

pub fn status_with_options(
    integration: Integration,
    options: &InstallOptions,
) -> anyhow::Result<IntegrationStatus> {
    if integration == Integration::Shell {
        return shell_status(options);
    }

    let (path, source) = match integration {
        Integration::Claude => (claude_config_path(&options.home), Source::ClaudeCode),
        Integration::Codex => (codex_config_path(&options.home), Source::Codex),
        Integration::Shell => unreachable!("handled above"),
    };
    let exists = path.exists();
    let expected_specs = match integration {
        Integration::Claude => claude_specs(&options.hook_path),
        Integration::Codex => codex_specs(&options.hook_path),
        Integration::Shell => unreachable!("handled above"),
    };
    let expected_hook_count = expected_specs.len();
    let mut installed_hook_count = 0;
    let mut stale_hook_paths = Vec::new();
    let mut missing_events = Vec::new();

    if exists {
        let value = read_json_or_empty(&path)?;
        installed_hook_count = count_source_hooks(&value, source);
        stale_hook_paths = collect_stale_hook_paths(&value, source, &options.hook_path);
        missing_events = expected_specs
            .iter()
            .filter(|spec| !has_expected_hook(&value, source, spec, &options.hook_path))
            .map(|spec| match spec.matcher {
                Some(matcher) => format!("{}:{matcher}", spec.event),
                None => spec.event.to_string(),
            })
            .collect();
    }

    let installed = installed_hook_count > 0;
    let expected_hook_path_exists = Path::new(&options.hook_path).exists();
    let configured = installed_hook_count >= expected_hook_count
        && stale_hook_paths.is_empty()
        && missing_events.is_empty()
        && expected_hook_path_exists;
    let requires_user_action = matches!(integration, Integration::Codex) && configured;
    let note = if !exists {
        format!(
            "Not installed. {} config file does not exist yet.",
            integration
        )
    } else if !installed {
        "Not installed. No WhileItThinks hooks found in this config.".to_string()
    } else if !stale_hook_paths.is_empty() {
        format!(
            "Hooks point at another app copy. Toggle this integration off and on to rewrite them to {}.",
            options.hook_path
        )
    } else if !expected_hook_path_exists {
        format!(
            "Hooks are configured, but the hook binary is missing at {}. Reinstall or move WhileItThinks.app back to that location.",
            options.hook_path
        )
    } else if !missing_events.is_empty() {
        format!(
            "Partially installed. Missing {} hook group(s): {}. Toggle off and on to repair.",
            missing_events.len(),
            missing_events.join(", ")
        )
    } else {
        match integration {
            Integration::Claude => {
                "Ready. Claude Code CLI and Desktop Code tab can send hooks through shared user settings.".to_string()
            }
            Integration::Codex => {
                "Configured. Codex requires one approval in the CLI /hooks screen before command hooks run.".to_string()
            }
            Integration::Shell => unreachable!("handled above"),
        }
    };

    Ok(IntegrationStatus {
        integration,
        config_path: path,
        config_exists: exists,
        installed,
        configured,
        installed_hook_count,
        expected_hook_count,
        expected_hook_path: options.hook_path.clone(),
        expected_hook_path_exists,
        stale_hook_paths,
        missing_events,
        requires_user_action,
        note,
    })
}

fn install_claude(options: &InstallOptions) -> anyhow::Result<InstallReport> {
    let path = claude_config_path(&options.home);
    let mut value = read_json_or_empty(&path)?;
    for spec in claude_specs(&options.hook_path) {
        upsert_hook_group(&mut value, Source::ClaudeCode, spec)?;
    }
    write_json_with_backup(&path, &value).map(|backup| InstallReport {
        integration: Integration::Claude,
        config_path: path,
        backup_path: backup,
        installed: true,
        note: "Claude Code hooks installed for CLI and Desktop Code tab shared user settings. No separate Claude trust step is required."
            .to_string(),
    })
}

fn install_codex(options: &InstallOptions) -> anyhow::Result<InstallReport> {
    let path = codex_config_path(&options.home);
    let mut value = read_json_or_empty(&path)?;
    for spec in codex_specs(&options.hook_path) {
        upsert_hook_group(&mut value, Source::Codex, spec)?;
    }
    write_json_with_backup(&path, &value).map(|backup| InstallReport {
        integration: Integration::Codex,
        config_path: path,
        backup_path: backup,
        installed: true,
        note:
            "Codex hooks installed. The user must approve WhileItThinks once from Codex CLI /hooks."
                .to_string(),
    })
}

fn install_shell(options: &InstallOptions) -> anyhow::Result<InstallReport> {
    let source_path = shell_source_path(&options.home);
    if let Some(parent) = source_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create shell integration dir {}", parent.display()))?;
    }
    fs::write(&source_path, shell_source_contents(&options.hook_path))
        .with_context(|| format!("write {}", source_path.display()))?;

    let zshrc = zshrc_path(&options.home);
    let existing = if zshrc.exists() {
        fs::read_to_string(&zshrc).with_context(|| format!("read {}", zshrc.display()))?
    } else {
        String::new()
    };
    let without_old = remove_marked_block(&existing);
    let marker = shell_marker_block(&source_path);
    let mut next = without_old.trim_end_matches('\n').to_string();
    if !next.is_empty() {
        next.push_str("\n\n");
    }
    next.push_str(&marker);
    next.push('\n');

    let backup = write_text_with_backup(&zshrc, &next)?;
    Ok(InstallReport {
        integration: Integration::Shell,
        config_path: zshrc,
        backup_path: backup,
        installed: true,
        note: "Shell fallback installed for new zsh tabs. Open a new Terminal tab before testing manual commands."
            .to_string(),
    })
}

fn uninstall_shell(options: &InstallOptions) -> anyhow::Result<InstallReport> {
    let zshrc = zshrc_path(&options.home);
    let backup = if zshrc.exists() {
        let existing =
            fs::read_to_string(&zshrc).with_context(|| format!("read {}", zshrc.display()))?;
        let next = remove_marked_block(&existing);
        write_text_with_backup(&zshrc, &next)?
    } else {
        None
    };

    let source_path = shell_source_path(&options.home);
    if source_path.exists() {
        fs::remove_file(&source_path)
            .with_context(|| format!("remove {}", source_path.display()))?;
    }

    Ok(InstallReport {
        integration: Integration::Shell,
        config_path: zshrc,
        backup_path: backup,
        installed: false,
        note: "Shell fallback removed from zsh startup.".to_string(),
    })
}

fn shell_status(options: &InstallOptions) -> anyhow::Result<IntegrationStatus> {
    let zshrc = zshrc_path(&options.home);
    let source_path = shell_source_path(&options.home);
    let zshrc_exists = zshrc.exists();
    let source_exists = source_path.exists();
    let source_loaded = zshrc_exists
        && fs::read_to_string(&zshrc)
            .map(|contents| {
                contents.contains(SHELL_MARKER_BEGIN) && contents.contains(SHELL_MARKER_END)
            })
            .unwrap_or(false);
    let source_contents = if source_exists {
        fs::read_to_string(&source_path).unwrap_or_default()
    } else {
        String::new()
    };
    let stale_hook_paths = extract_shell_hook_path(&source_contents)
        .filter(|path| path != &options.hook_path)
        .map(|path| vec![path])
        .unwrap_or_default();
    let expected_hook_path_exists = Path::new(&options.hook_path).exists();
    let missing_events = [
        (!source_loaded).then_some("zsh startup block"),
        (!source_exists).then_some("zsh source file"),
    ]
    .into_iter()
    .flatten()
    .map(ToOwned::to_owned)
    .collect::<Vec<_>>();
    let installed = source_loaded || source_exists;
    let configured = source_loaded
        && source_exists
        && stale_hook_paths.is_empty()
        && expected_hook_path_exists
        && source_contents.contains("--source shell")
        && source_contents.contains("--command-stdin");
    let note = if !installed {
        "Optional. Turn this on if you want WhileItThinks to watch commands you type in zsh Terminal."
            .to_string()
    } else if !stale_hook_paths.is_empty() {
        "Shell fallback points at another app copy. Toggle it off and on to repair.".to_string()
    } else if !expected_hook_path_exists {
        format!(
            "Shell fallback is installed, but the hook binary is missing at {}.",
            options.hook_path
        )
    } else if !configured {
        "Shell fallback is incomplete. Toggle it off and on to repair.".to_string()
    } else {
        "Ready. New zsh Terminal tabs can send manual command wait states.".to_string()
    };

    Ok(IntegrationStatus {
        integration: Integration::Shell,
        config_path: zshrc,
        config_exists: zshrc_exists,
        installed,
        configured,
        installed_hook_count: usize::from(source_loaded),
        expected_hook_count: 1,
        expected_hook_path: options.hook_path.clone(),
        expected_hook_path_exists,
        stale_hook_paths,
        missing_events,
        requires_user_action: false,
        note,
    })
}

fn uninstall_integration(
    integration: Integration,
    path: &Path,
    source: Source,
) -> anyhow::Result<InstallReport> {
    if !path.exists() {
        return Ok(InstallReport {
            integration,
            config_path: path.to_path_buf(),
            backup_path: None,
            installed: false,
            note: "Config file does not exist; nothing to uninstall.".to_string(),
        });
    }

    let mut value = read_json_or_empty(path)?;
    remove_source_hooks(&mut value, source);
    write_json_with_backup(path, &value).map(|backup| InstallReport {
        integration,
        config_path: path.to_path_buf(),
        backup_path: backup,
        installed: false,
        note: "WhileItThinks hooks removed.".to_string(),
    })
}

#[derive(Debug, Clone)]
struct HookSpec {
    event: &'static str,
    matcher: Option<&'static str>,
    command: String,
    status_message: Option<&'static str>,
}

fn claude_specs(hook_path: &str) -> Vec<HookSpec> {
    vec![
        HookSpec::new("SessionStart", None, hook_path, Source::ClaudeCode),
        HookSpec::new("UserPromptSubmit", None, hook_path, Source::ClaudeCode),
        HookSpec::new("PreToolUse", Some("Bash"), hook_path, Source::ClaudeCode),
        HookSpec::new(
            "PreToolUse",
            Some("Edit|Write|MultiEdit"),
            hook_path,
            Source::ClaudeCode,
        ),
        HookSpec::new(
            "PostToolUse",
            Some("Bash|Edit|Write|MultiEdit"),
            hook_path,
            Source::ClaudeCode,
        ),
        HookSpec::new(
            "PostToolUseFailure",
            Some("Bash"),
            hook_path,
            Source::ClaudeCode,
        ),
        HookSpec::new(
            "Notification",
            Some("permission_prompt|idle_prompt"),
            hook_path,
            Source::ClaudeCode,
        ),
        HookSpec::new("PermissionRequest", None, hook_path, Source::ClaudeCode),
        HookSpec::new("Stop", None, hook_path, Source::ClaudeCode),
    ]
}

fn codex_specs(hook_path: &str) -> Vec<HookSpec> {
    vec![
        HookSpec::codex("SessionStart", None, hook_path),
        HookSpec::codex("UserPromptSubmit", None, hook_path),
        HookSpec::codex("PreToolUse", Some("^Bash$"), hook_path),
        HookSpec::codex("PreToolUse", Some("^(apply_patch|Edit|Write)$"), hook_path),
        HookSpec::codex(
            "PostToolUse",
            Some("^(Bash|apply_patch|Edit|Write)$"),
            hook_path,
        ),
        HookSpec::codex("PermissionRequest", None, hook_path),
        HookSpec::codex("Stop", None, hook_path),
    ]
}

impl HookSpec {
    fn new(
        event: &'static str,
        matcher: Option<&'static str>,
        hook_path: &str,
        source: Source,
    ) -> Self {
        Self {
            event,
            matcher,
            command: hook_command(hook_path, source, event),
            status_message: None,
        }
    }

    fn codex(event: &'static str, matcher: Option<&'static str>, hook_path: &str) -> Self {
        Self {
            event,
            matcher,
            command: hook_command(hook_path, Source::Codex, event),
            status_message: Some("WhileItThinks"),
        }
    }
}

fn upsert_hook_group(value: &mut Value, source: Source, spec: HookSpec) -> anyhow::Result<()> {
    ensure_object(value)?;
    remove_matching_hook(value, source, spec.event, spec.matcher);

    let hooks = value
        .as_object_mut()
        .expect("object checked")
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::new()));
    ensure_object(hooks)?;

    let event_groups = hooks
        .as_object_mut()
        .expect("object checked")
        .entry(spec.event)
        .or_insert_with(|| Value::Array(Vec::new()));
    if !event_groups.is_array() {
        bail!("hooks.{} must be an array", spec.event);
    }

    let mut hook = json!({
        "type": "command",
        "command": spec.command,
        "timeout": 5,
    });
    if let Some(status_message) = spec.status_message {
        hook.as_object_mut().expect("hook object").insert(
            "statusMessage".to_string(),
            Value::String(status_message.to_string()),
        );
    }

    let mut group = Map::new();
    if let Some(matcher) = spec.matcher {
        group.insert("matcher".to_string(), Value::String(matcher.to_string()));
    }
    group.insert("hooks".to_string(), Value::Array(vec![hook]));

    event_groups
        .as_array_mut()
        .expect("array checked")
        .push(Value::Object(group));
    Ok(())
}

fn remove_matching_hook(value: &mut Value, source: Source, event: &str, matcher: Option<&str>) {
    let Some(groups) = value
        .get_mut("hooks")
        .and_then(|hooks| hooks.get_mut(event))
        .and_then(Value::as_array_mut)
    else {
        return;
    };

    for group in groups.iter_mut() {
        let group_matcher = group.get("matcher").and_then(Value::as_str);
        if group_matcher != matcher {
            continue;
        }
        if let Some(hooks) = group.get_mut("hooks").and_then(Value::as_array_mut) {
            hooks.retain(|hook| !is_whileitthinks_hook(hook, Some(source), Some(event)));
        }
    }
    groups.retain(|group| {
        group
            .get("hooks")
            .and_then(Value::as_array)
            .map(|hooks| !hooks.is_empty())
            .unwrap_or(true)
    });
}

fn remove_source_hooks(value: &mut Value, source: Source) {
    let Some(hooks_object) = value.get_mut("hooks").and_then(Value::as_object_mut) else {
        return;
    };

    let events: Vec<String> = hooks_object.keys().cloned().collect();
    for event in events {
        let Some(groups) = hooks_object.get_mut(&event).and_then(Value::as_array_mut) else {
            continue;
        };
        for group in groups.iter_mut() {
            if let Some(hooks) = group.get_mut("hooks").and_then(Value::as_array_mut) {
                hooks.retain(|hook| !is_whileitthinks_hook(hook, Some(source), None));
            }
        }
        groups.retain(|group| {
            group
                .get("hooks")
                .and_then(Value::as_array)
                .map(|hooks| !hooks.is_empty())
                .unwrap_or(true)
        });
    }

    hooks_object.retain(|_, groups| {
        groups
            .as_array()
            .map(|items| !items.is_empty())
            .unwrap_or(true)
    });
}

fn count_source_hooks(value: &Value, source: Source) -> usize {
    value
        .get("hooks")
        .and_then(Value::as_object)
        .map(|hooks| {
            hooks.values().fold(0, |count, groups| {
                groups
                    .as_array()
                    .map(|groups| {
                        count
                            + groups
                                .iter()
                                .map(|group| {
                                    group
                                        .get("hooks")
                                        .and_then(Value::as_array)
                                        .map(|hooks| {
                                            hooks
                                                .iter()
                                                .filter(|hook| {
                                                    is_whileitthinks_hook(hook, Some(source), None)
                                                })
                                                .count()
                                        })
                                        .unwrap_or(0)
                                })
                                .sum::<usize>()
                    })
                    .unwrap_or(count)
            })
        })
        .unwrap_or(0)
}

fn has_expected_hook(value: &Value, source: Source, spec: &HookSpec, hook_path: &str) -> bool {
    value
        .get("hooks")
        .and_then(|hooks| hooks.get(spec.event))
        .and_then(Value::as_array)
        .map(|groups| {
            groups.iter().any(|group| {
                let group_matcher = group.get("matcher").and_then(Value::as_str);
                group_matcher == spec.matcher
                    && group
                        .get("hooks")
                        .and_then(Value::as_array)
                        .map(|hooks| {
                            hooks.iter().any(|hook| {
                                hook_command_matches(hook, source, spec.event, hook_path)
                            })
                        })
                        .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn collect_stale_hook_paths(value: &Value, source: Source, expected_path: &str) -> Vec<String> {
    let mut paths = Vec::new();
    let Some(hooks_object) = value.get("hooks").and_then(Value::as_object) else {
        return paths;
    };

    for groups in hooks_object.values() {
        let Some(groups) = groups.as_array() else {
            continue;
        };
        for group in groups {
            let Some(hooks) = group.get("hooks").and_then(Value::as_array) else {
                continue;
            };
            for hook in hooks {
                if !is_whileitthinks_hook(hook, Some(source), None) {
                    continue;
                }
                if let Some(command) = hook.get("command").and_then(Value::as_str) {
                    if let Some(path) = extract_hook_binary_path(command) {
                        if path != expected_path && !paths.contains(&path) {
                            paths.push(path);
                        }
                    }
                }
            }
        }
    }
    paths
}

fn hook_command_matches(hook: &Value, source: Source, event: &str, hook_path: &str) -> bool {
    let Some(command) = hook.get("command").and_then(Value::as_str) else {
        return false;
    };
    command.contains("whileitthinks-hook")
        && command.contains(&format!("--source {}", source_arg(source)))
        && command.contains(&format!("--event {event}"))
        && extract_hook_binary_path(command)
            .as_deref()
            .map(|path| path == hook_path)
            .unwrap_or(false)
}

fn extract_hook_binary_path(command: &str) -> Option<String> {
    if let Some(rest) = command.strip_prefix('"') {
        return rest.split('"').next().map(ToOwned::to_owned);
    }
    command
        .split_whitespace()
        .find(|part| part.contains("whileitthinks-hook"))
        .map(|part| part.trim_matches('"').to_string())
}

fn is_whileitthinks_hook(hook: &Value, source: Option<Source>, event: Option<&str>) -> bool {
    let Some(command) = hook.get("command").and_then(Value::as_str) else {
        return false;
    };
    if !command.contains("whileitthinks-hook") {
        return false;
    }
    if let Some(source) = source {
        if !command.contains(&format!("--source {}", source_arg(source))) {
            return false;
        }
    }
    if let Some(event) = event {
        if !command.contains(&format!("--event {event}")) {
            return false;
        }
    }
    true
}

fn hook_command(hook_path: &str, source: Source, event: &str) -> String {
    format!(
        "\"{}\" --source {} --event {}",
        hook_path.replace('"', "\\\""),
        source_arg(source),
        event
    )
}

fn source_arg(source: Source) -> &'static str {
    match source {
        Source::ClaudeCode => "claude-code",
        Source::Codex => "codex",
        Source::Shell => "shell",
        Source::Macos => "macos",
    }
}

const SHELL_MARKER_BEGIN: &str = "# >>> whileitthinks shell integration >>>";
const SHELL_MARKER_END: &str = "# <<< whileitthinks shell integration <<<";

fn shell_marker_block(source_path: &Path) -> String {
    format!(
        "{SHELL_MARKER_BEGIN}\nsource {}\n{SHELL_MARKER_END}",
        shell_quote(&source_path.to_string_lossy())
    )
}

fn shell_source_contents(hook_path: &str) -> String {
    format!(
        r#"# WhileItThinks zsh integration. Generated by WhileItThinks.
# This file is local-only and fails open when the app is not running.

if [[ -z "${{__WHILEITTHINKS_ZSH_LOADED:-}}" ]]; then
  typeset -g __WHILEITTHINKS_ZSH_LOADED=1
  typeset -g __whileitthinks_hook={hook}
  typeset -g __whileitthinks_command_id=""
  typeset -g __whileitthinks_command_text=""

  __whileitthinks_send() {{
    emulate -L zsh
    local event="$1"
    local exit_code="${{2:-}}"
    local command="${{3:-}}"
    [[ -x "$__whileitthinks_hook" ]] || return 0

    local -a args
    args=(--source shell --surface cli --event "$event" --cwd "$PWD" --session-id "$__whileitthinks_command_id" --command-stdin)
    if [[ -n "$exit_code" ]]; then
      args+=(--exit-code "$exit_code")
    fi

    printf '%s' "$command" | "$__whileitthinks_hook" "${{args[@]}}" >/dev/null 2>&1 &
  }}

  __whileitthinks_preexec() {{
    emulate -L zsh
    __whileitthinks_command_id="${{EPOCHSECONDS:-$(date +%s)}}-$$-$RANDOM"
    __whileitthinks_command_text="$1"
    __whileitthinks_send shell_started "" "$__whileitthinks_command_text"
  }}

  __whileitthinks_precmd() {{
    local exit_code=$?
    emulate -L zsh
    if [[ -n "${{__whileitthinks_command_id:-}}" ]]; then
      __whileitthinks_send shell_finished "$exit_code" "$__whileitthinks_command_text"
      __whileitthinks_command_id=""
      __whileitthinks_command_text=""
    fi
    return "$exit_code"
  }}

  autoload -Uz add-zsh-hook
  add-zsh-hook -d preexec __whileitthinks_preexec 2>/dev/null || true
  add-zsh-hook -d precmd __whileitthinks_precmd 2>/dev/null || true
  add-zsh-hook preexec __whileitthinks_preexec
  add-zsh-hook precmd __whileitthinks_precmd
fi
"#,
        hook = shell_quote(hook_path)
    )
}

fn remove_marked_block(contents: &str) -> String {
    let mut result = contents.to_string();
    while let Some(begin) = result.find(SHELL_MARKER_BEGIN) {
        let search_after_begin = begin + SHELL_MARKER_BEGIN.len();
        let Some(end_offset) = result[search_after_begin..].find(SHELL_MARKER_END) else {
            break;
        };
        let end = search_after_begin + end_offset + SHELL_MARKER_END.len();
        let remove_end = if result[end..].starts_with("\r\n") {
            end + 2
        } else if result[end..].starts_with('\n') {
            end + 1
        } else {
            end
        };
        result.replace_range(begin..remove_end, "");
    }
    result
}

fn extract_shell_hook_path(contents: &str) -> Option<String> {
    let line = contents.lines().find(|line| {
        line.trim_start()
            .starts_with("typeset -g __whileitthinks_hook=")
    })?;
    let value = line.split_once('=')?.1.trim();
    shell_unquote(value)
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn shell_unquote(value: &str) -> Option<String> {
    let value = value.trim();
    if let Some(inner) = value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')) {
        return Some(inner.replace("'\\''", "'"));
    }
    Some(value.trim_matches('"').to_string()).filter(|value| !value.is_empty())
}

fn read_json_or_empty(path: &Path) -> anyhow::Result<Value> {
    if !path.exists() {
        return Ok(json!({}));
    }
    let contents =
        fs::read_to_string(path).with_context(|| format!("read config {}", path.display()))?;
    if contents.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(&contents).with_context(|| format!("parse JSON config {}", path.display()))
}

fn write_json_with_backup(path: &Path, value: &Value) -> anyhow::Result<Option<PathBuf>> {
    ensure_object(value)?;
    let backup = if path.exists() {
        let backup_path = backup_path(path)?;
        fs::copy(path, &backup_path)
            .with_context(|| format!("backup {} to {}", path.display(), backup_path.display()))?;
        Some(backup_path)
    } else {
        None
    };

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create config directory {}", parent.display()))?;
    }
    let tmp_path = path.with_file_name(format!(
        ".{}.tmp-{}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("config"),
        Uuid::new_v4()
    ));
    let bytes = serde_json::to_vec_pretty(value)?;
    fs::write(&tmp_path, bytes).with_context(|| format!("write {}", tmp_path.display()))?;
    fs::rename(&tmp_path, path).with_context(|| format!("replace config {}", path.display()))?;
    Ok(backup)
}

fn write_text_with_backup(path: &Path, contents: &str) -> anyhow::Result<Option<PathBuf>> {
    let backup = if path.exists() {
        let backup_path = backup_path(path)?;
        fs::copy(path, &backup_path)
            .with_context(|| format!("backup {} to {}", path.display(), backup_path.display()))?;
        Some(backup_path)
    } else {
        None
    };

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create config directory {}", parent.display()))?;
    }
    let tmp_path = path.with_file_name(format!(
        ".{}.tmp-{}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("config"),
        Uuid::new_v4()
    ));
    fs::write(&tmp_path, contents).with_context(|| format!("write {}", tmp_path.display()))?;
    fs::rename(&tmp_path, path).with_context(|| format!("replace config {}", path.display()))?;
    Ok(backup)
}

fn backup_path(path: &Path) -> anyhow::Result<PathBuf> {
    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .context("config path must have a file name")?;
    let timestamp = Utc::now().format("%Y-%m-%dT%H-%M-%S");
    Ok(path.with_file_name(format!("{filename}.whileitthinks-backup-{timestamp}")))
}

fn ensure_object(value: &Value) -> anyhow::Result<()> {
    if value.is_object() {
        Ok(())
    } else {
        bail!("config root must be a JSON object")
    }
}

fn claude_config_path(home: &Path) -> PathBuf {
    home.join(".claude").join("settings.json")
}

fn codex_config_path(home: &Path) -> PathBuf {
    home.join(".codex").join("hooks.json")
}

fn zshrc_path(home: &Path) -> PathBuf {
    home.join(".zshrc")
}

fn shell_source_path(home: &Path) -> PathBuf {
    home.join("Library")
        .join("Application Support")
        .join("WhileItThinks")
        .join("shell")
        .join("zsh.zsh")
}

pub fn discover_hook_path() -> String {
    let from_current_exe = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|parent| parent.join("whileitthinks-hook")))
        .filter(|candidate| candidate.exists());
    from_current_exe
        .unwrap_or_else(|| PathBuf::from(default_installed_hook_path()))
        .to_string_lossy()
        .to_string()
}
