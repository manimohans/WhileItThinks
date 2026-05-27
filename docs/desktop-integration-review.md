# Desktop Integration Review

## Current Launch Scope

WhileItThinks now targets Claude Code and Codex only:

- Claude Code CLI
- Claude Desktop Code tab, through the same Claude Code user settings
- Codex CLI
- Codex Desktop app, through shared Codex agent configuration

VS Code and Cursor are intentionally out of scope for this pass.

## Desktop App Architecture

`WhileItThinks.app` is a SwiftUI macOS app that embeds the Rust engine binaries:

- `whileitthinksd`: local event daemon
- `whileitthinks-hook`: fail-open hook bridge called by Claude/Codex
- `whileitthinks-cli`: installer/status/test CLI used by the app

The app starts the daemon, requests notifications, offers optional Accessibility permission, installs/uninstalls hooks, includes a setup tutorial, and reads daemon wait-state results to show a small non-modal overlay plus local completion/approval notifications.

## Claude Code Compatibility

The installer writes user-level hooks into `~/.claude/settings.json`, preserving existing settings and creating timestamped backups. Claude Code user settings apply across projects. The in-app tutorial tells users to run `/status` in Claude if they want to confirm active settings.

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

## Remaining Production Work

- Sign and notarize `WhileItThinks.app`.
- Replace the app-owned daemon process with a proper login item/helper before public release.
- Add real smoke scripts for Claude CLI/Desktop and Codex CLI/Desktop after installing hooks on a test machine.
