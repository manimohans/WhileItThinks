pub const DESKTOP_APP_GUIDE: &str = r#"WhileItThinks setup

1. Keep WhileItThinks open.
   The app starts the local event daemon. Claude Code and Codex hooks send local-only events to it.

2. Enable Claude Code.
   Turn on Claude Code in the app. WhileItThinks merges command hooks into ~/.claude/settings.json and creates a timestamped backup first.
   Claude Code reloads hooks from user settings. This covers Claude Code CLI and the Claude Desktop Code tab when they use the same user configuration.
   No separate Claude trust step is required. Do not test with claude --bare because bare mode skips hooks.
   Optional verification: open Claude Code and run /status to confirm user settings are active, or /hooks to inspect the WhileItThinks hook handlers.

3. Enable Codex.
   Turn on Codex in the app. WhileItThinks writes ~/.codex/hooks.json and creates a timestamped backup first.
   Required manual trust step: open Terminal, run codex, type /hooks in the Codex CLI, review WhileItThinks, and trust the command hooks. Codex Desktop does not currently expose /hooks in chat. Codex will skip non-managed hooks until this is done.
   This covers Codex CLI and Codex Desktop app agents because app agents inherit the same configuration as the IDE and CLI extension.

4. Allow notifications.
   Notifications are used only for approval prompts that need your attention. Finished commands stay silent. No account or cloud sync is used.

5. Accessibility is not required.
   Claude/Codex hook ingestion does not require Accessibility. Leave it off unless you want to try future active-app/fullscreen suppression controls in Settings.

Privacy defaults:
WhileItThinks stores sanitized local metadata only: source, event kind, duration, exit code, command category, and hashed project/session identifiers. It does not store prompts, assistant text, file contents, shell output, or raw command arguments by default.
"#;
