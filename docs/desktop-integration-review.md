# Desktop Integration Review

## Current Launch Scope

WhileItThinks now targets Claude Code and Codex only:

- Claude Code CLI
- Claude Desktop Code tab, through the same Claude Code user settings
- Codex CLI
- Codex Desktop app, through shared Codex agent configuration
- Optional zsh Terminal commands, through a user-level shell snippet

VS Code and Cursor are intentionally out of scope for this pass.

## Desktop App Architecture

`WhileItThinks.app` is a SwiftUI macOS app that embeds the Rust engine binaries:

- `whileitthinksd`: local event receiver daemon
- `whileitthinks-hook`: fail-open hook bridge called by Claude/Codex
- `whileitthinks-cli`: installer/status/test CLI used by the app

The app manages a user LaunchAgent at `~/Library/LaunchAgents/com.whileitthinks.daemon.plist`, requests notification permission for approval prompts, installs/uninstalls hooks, includes a setup tutorial, and reads receiver wait-state results to show a small non-modal overlay. Accessibility is not part of first-run setup; it remains an optional advanced control for future active-app/fullscreen suppression.

## Claude Code Compatibility

The installer writes user-level hooks into `~/.claude/settings.json`, preserving existing settings and creating timestamped backups. Claude Code user settings apply across projects. Claude Desktop Code tab sessions use the same Claude Code settings and hook system as the CLI, so this one user-level install covers both surfaces.

Claude Code does not require the separate hook trust step that Codex requires. The in-app tutorial tells users to use normal Claude Code sessions, not `claude --bare`, because bare mode skips hooks. For verification, users can run `/status` to confirm user settings are loaded or `/hooks` to inspect the configured WhileItThinks hook handlers.

Installed Claude events:

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse` for `Bash` and file-edit tools
- `PostToolUse` for `Bash` and file-edit tools
- `PostToolUseFailure` for `Bash`
- `Notification` for permission/idle prompts
- `PermissionRequest`
- `Stop`

## Codex Compatibility

The installer writes `~/.codex/hooks.json` and does not modify `~/.codex/config.toml`. Codex discovers hooks from `hooks.json` next to active config layers. Non-managed command hooks require review and trust. Codex Desktop does not currently expose the hook browser in its chat UI, so the app and CLI instruct the user to run `codex` in Terminal, type `/hooks` in the Codex CLI, and trust WhileItThinks there once.

Installed Codex events:

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse` for `Bash` and `apply_patch` aliases
- `PostToolUse` for `Bash` and `apply_patch` aliases
- `PermissionRequest`
- `Stop`

## Shell Fallback Compatibility

The optional zsh fallback writes a generated source file to `~/Library/Application Support/WhileItThinks/shell/zsh.zsh` and adds one marked source block to `~/.zshrc`. It uses zsh `preexec` and `precmd` hooks to send `shell_started` and `shell_finished` through `whileitthinks-hook --source shell`.

The shell fallback passes command text through stdin with `--command-stdin`, not process arguments. Users must open a new Terminal tab after enabling it.

## Remaining Production Work

- Sign and notarize `WhileItThinks.app`.
- Add real smoke scripts for Claude CLI/Desktop and Codex CLI/Desktop after installing hooks on a test machine.
