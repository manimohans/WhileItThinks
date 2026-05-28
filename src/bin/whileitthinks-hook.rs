use std::io::{self, IsTerminal, Read};
use std::process::ExitCode;

use clap::{Parser, ValueEnum};
use serde_json::Value;
use whileitthinks::event::{Source, Surface};
use whileitthinks::mapper::{map_hook, HookInput};
use whileitthinks::transport::send_event;

#[derive(Debug, Parser)]
#[command(name = "whileitthinks-hook")]
#[command(about = "Fast fail-open hook bridge for Claude Code and Codex")]
struct Args {
    #[arg(long, value_enum)]
    source: SourceArg,
    #[arg(long)]
    event: String,
    #[arg(long, value_enum, default_value = "unknown")]
    surface: SurfaceArg,
    #[arg(long)]
    command: Option<String>,
    #[arg(long)]
    cwd: Option<String>,
    #[arg(long)]
    session_id: Option<String>,
    #[arg(long)]
    command_stdin: bool,
    #[arg(long)]
    exit_code: Option<i32>,
    #[arg(long)]
    duration_ms: Option<i64>,
    #[arg(long)]
    print: bool,
    #[arg(long)]
    verbose: bool,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum SourceArg {
    #[value(name = "claude-code")]
    ClaudeCode,
    Codex,
    Shell,
    Macos,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum SurfaceArg {
    Cli,
    Desktop,
    Unknown,
}

#[tokio::main]
async fn main() -> ExitCode {
    let args = Args::parse();
    if let Err(error) = run(args).await {
        if std::env::var_os("WHILEITTHINKS_HOOK_DEBUG").is_some() {
            eprintln!("whileitthinks-hook: {error:#}");
        }
    }
    ExitCode::SUCCESS
}

async fn run(args: Args) -> anyhow::Result<()> {
    let mut command = args.command;
    let raw = if args.command_stdin {
        let stdin_command = read_stdin_text()?;
        if !stdin_command.is_empty() {
            command = Some(stdin_command);
        }
        Value::Object(Default::default())
    } else {
        read_stdin_json()?
    };
    let input = HookInput {
        source: args.source.into(),
        surface: args.surface.into(),
        event_name: args.event,
        command,
        cwd: args.cwd,
        session_id: args.session_id,
        exit_code: args.exit_code,
        duration_ms: args.duration_ms,
        raw,
    };

    let events = map_hook(input);
    if args.print {
        println!("{}", serde_json::to_string_pretty(&events)?);
    }

    for event in events {
        match send_event(&event).await {
            Ok(delivery) if args.verbose => {
                eprintln!(
                    "whileitthinks-hook: delivered via {:?} to {}",
                    delivery.channel, delivery.endpoint
                );
            }
            Ok(_) => {}
            Err(error) if args.verbose => {
                eprintln!("whileitthinks-hook: send failed: {error:#}");
            }
            Err(_) => {}
        }
    }
    Ok(())
}

fn read_stdin_json() -> anyhow::Result<Value> {
    if io::stdin().is_terminal() {
        return Ok(Value::Object(Default::default()));
    }
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    if input.trim().is_empty() {
        return Ok(Value::Object(Default::default()));
    }
    Ok(serde_json::from_str(&input)?)
}

fn read_stdin_text() -> anyhow::Result<String> {
    if io::stdin().is_terminal() {
        return Ok(String::new());
    }
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    Ok(input)
}

impl From<SourceArg> for Source {
    fn from(value: SourceArg) -> Self {
        match value {
            SourceArg::ClaudeCode => Source::ClaudeCode,
            SourceArg::Codex => Source::Codex,
            SourceArg::Shell => Source::Shell,
            SourceArg::Macos => Source::Macos,
        }
    }
}

impl From<SurfaceArg> for Surface {
    fn from(value: SurfaceArg) -> Self {
        match value {
            SurfaceArg::Cli => Surface::Cli,
            SurfaceArg::Desktop => Surface::Desktop,
            SurfaceArg::Unknown => Surface::Unknown,
        }
    }
}
