use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{bail, Context};
use serde::Serialize;

use crate::paths::{default_installed_daemon_path, home_dir, HTTP_ADDR};

pub const DAEMON_LABEL: &str = "com.whileitthinks.daemon";

#[derive(Debug, Clone)]
pub struct DaemonOptions {
    pub home: PathBuf,
    pub daemon_path: String,
}

impl Default for DaemonOptions {
    fn default() -> Self {
        Self {
            home: home_dir(),
            daemon_path: discover_daemon_path(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DaemonStatus {
    pub label: String,
    pub plist_path: PathBuf,
    pub installed: bool,
    pub loaded: bool,
    pub healthy: bool,
    pub configured: bool,
    pub expected_daemon_path: String,
    pub expected_daemon_path_exists: bool,
    pub stale_daemon_paths: Vec<String>,
    pub note: String,
}

pub fn status_with_options(options: &DaemonOptions) -> anyhow::Result<DaemonStatus> {
    let plist_path = launch_agent_plist_path(&options.home);
    let installed = plist_path.exists();
    let expected_daemon_path_exists = Path::new(&options.daemon_path).is_file();
    let actual_daemon_path = if installed {
        fs::read_to_string(&plist_path)
            .ok()
            .and_then(|contents| extract_daemon_path_from_plist(&contents))
    } else {
        None
    };
    let stale_daemon_paths = actual_daemon_path
        .as_ref()
        .filter(|path| *path != &options.daemon_path)
        .map(|path| vec![path.clone()])
        .unwrap_or_default();
    let loaded = launchctl_print().unwrap_or(false);
    let healthy = daemon_health_check();
    let configured = installed
        && expected_daemon_path_exists
        && stale_daemon_paths.is_empty()
        && actual_daemon_path.as_deref() == Some(options.daemon_path.as_str());

    let note = if !installed && healthy {
        "Running. A local receiver is accepting events, but this app has not installed its background helper yet."
            .to_string()
    } else if !installed {
        "Not installed. Start the local receiver to create the background helper.".to_string()
    } else if !stale_daemon_paths.is_empty() {
        "Installed, but it points at another app copy. Repair the local receiver.".to_string()
    } else if !expected_daemon_path_exists {
        format!(
            "Installed, but the daemon binary is missing at {}. Move WhileItThinks.app back or reinstall.",
            options.daemon_path
        )
    } else if healthy {
        "Running. Hooks can send local events to the background receiver.".to_string()
    } else if loaded {
        "Background helper is loaded, but the health check is not answering yet.".to_string()
    } else {
        "Installed but not loaded. Start or repair the local receiver.".to_string()
    };

    Ok(DaemonStatus {
        label: DAEMON_LABEL.to_string(),
        plist_path,
        installed,
        loaded,
        healthy,
        configured,
        expected_daemon_path: options.daemon_path.clone(),
        expected_daemon_path_exists,
        stale_daemon_paths,
        note,
    })
}

pub fn install_with_options(options: &DaemonOptions) -> anyhow::Result<DaemonStatus> {
    if !Path::new(&options.daemon_path).is_file() {
        bail!("daemon binary missing at {}", options.daemon_path);
    }

    let plist_path = launch_agent_plist_path(&options.home);
    if let Some(parent) = plist_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create launch agents dir {}", parent.display()))?;
    }
    let log_dir = app_support_dir_for_home(&options.home).join("logs");
    fs::create_dir_all(&log_dir)
        .with_context(|| format!("create log dir {}", log_dir.display()))?;

    let plist = launch_agent_plist(options);
    fs::write(&plist_path, plist).with_context(|| format!("write {}", plist_path.display()))?;

    let _ = launchctl(&["bootout", &launchctl_service_target()]);
    stop_stray_daemons();
    launchctl(&[
        "bootstrap",
        &launchctl_gui_target(),
        plist_path.to_string_lossy().as_ref(),
    ])?;
    launchctl(&["kickstart", "-k", &launchctl_service_target()])?;

    status_with_options(options)
}

pub fn uninstall_with_options(options: &DaemonOptions) -> anyhow::Result<DaemonStatus> {
    let plist_path = launch_agent_plist_path(&options.home);
    let _ = launchctl(&["bootout", &launchctl_service_target()]);
    if plist_path.exists() {
        fs::remove_file(&plist_path).with_context(|| format!("remove {}", plist_path.display()))?;
    }
    status_with_options(options)
}

pub fn restart_with_options(options: &DaemonOptions) -> anyhow::Result<DaemonStatus> {
    let current = status_with_options(options)?;
    if !current.installed || !current.configured {
        return install_with_options(options);
    }

    if launchctl(&["kickstart", "-k", &launchctl_service_target()]).is_err() {
        launchctl(&[
            "bootstrap",
            &launchctl_gui_target(),
            current.plist_path.to_string_lossy().as_ref(),
        ])?;
        launchctl(&["kickstart", "-k", &launchctl_service_target()])?;
    }
    status_with_options(options)
}

pub fn launch_agent_plist(options: &DaemonOptions) -> String {
    let log_dir = app_support_dir_for_home(&options.home).join("logs");
    let stdout = log_dir.join("whileitthinksd.out.log");
    let stderr = log_dir.join("whileitthinksd.err.log");
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{daemon}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key>
    <true/>
  </dict>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#,
        label = xml_escape(DAEMON_LABEL),
        daemon = xml_escape(&options.daemon_path),
        stdout = xml_escape(&stdout.to_string_lossy()),
        stderr = xml_escape(&stderr.to_string_lossy())
    )
}

pub fn launch_agent_plist_path(home: &Path) -> PathBuf {
    home.join("Library")
        .join("LaunchAgents")
        .join(format!("{DAEMON_LABEL}.plist"))
}

pub fn discover_daemon_path() -> String {
    let from_current_exe = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|parent| parent.join("whileitthinksd")))
        .filter(|candidate| candidate.exists());
    from_current_exe
        .unwrap_or_else(|| PathBuf::from(default_installed_daemon_path()))
        .to_string_lossy()
        .to_string()
}

fn app_support_dir_for_home(home: &Path) -> PathBuf {
    home.join("Library")
        .join("Application Support")
        .join("WhileItThinks")
}

fn extract_daemon_path_from_plist(contents: &str) -> Option<String> {
    let program_args = contents.split("<key>ProgramArguments</key>").nth(1)?;
    let first_string = program_args.split("<string>").nth(1)?;
    first_string
        .split("</string>")
        .next()
        .map(xml_unescape)
        .filter(|value| !value.is_empty())
}

fn launchctl_print() -> anyhow::Result<bool> {
    Ok(Command::new("/bin/launchctl")
        .args(["print", &launchctl_service_target()])
        .output()
        .context("run launchctl print")?
        .status
        .success())
}

fn launchctl(args: &[&str]) -> anyhow::Result<()> {
    let output = Command::new("/bin/launchctl")
        .args(args)
        .output()
        .context("run launchctl")?;
    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    bail!("launchctl {} failed: {}", args.join(" "), stderr.trim());
}

fn stop_stray_daemons() {
    let _ = Command::new("/usr/bin/pkill")
        .args(["-x", "whileitthinksd"])
        .output();
}

fn launchctl_gui_target() -> String {
    format!("gui/{}", current_uid())
}

fn launchctl_service_target() -> String {
    format!("{}/{}", launchctl_gui_target(), DAEMON_LABEL)
}

fn current_uid() -> String {
    Command::new("/usr/bin/id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|output| {
            if output.status.success() {
                Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
            } else {
                None
            }
        })
        .filter(|uid| !uid.is_empty())
        .unwrap_or_else(|| "501".to_string())
}

fn daemon_health_check() -> bool {
    let Ok(addr) = HTTP_ADDR.parse::<SocketAddr>() else {
        return false;
    };
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, Duration::from_millis(250)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
    if stream
        .write_all(b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        .is_err()
    {
        return false;
    }

    let mut response = String::new();
    stream.read_to_string(&mut response).is_ok() && response.starts_with("HTTP/1.1 200")
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn xml_unescape(value: &str) -> String {
    value
        .replace("&apos;", "'")
        .replace("&quot;", "\"")
        .replace("&gt;", ">")
        .replace("&lt;", "<")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn launch_agent_plist_contains_expected_daemon_and_run_at_load() {
        let temp = TempDir::new().unwrap();
        let options = DaemonOptions {
            home: temp.path().to_path_buf(),
            daemon_path: "/Applications/WhileItThinks.app/Contents/MacOS/whileitthinksd"
                .to_string(),
        };
        let plist = launch_agent_plist(&options);
        assert!(plist.contains(DAEMON_LABEL));
        assert!(plist.contains(&options.daemon_path));
        assert!(plist.contains("<key>RunAtLoad</key>"));
        assert!(plist.contains("<true/>"));
        assert!(plist.contains("whileitthinksd.out.log"));
    }

    #[test]
    fn daemon_status_detects_missing_and_stale_plists_without_launchctl_dependency() {
        let temp = TempDir::new().unwrap();
        let expected = temp.path().join("new").join("whileitthinksd");
        fs::create_dir_all(expected.parent().unwrap()).unwrap();
        fs::write(&expected, "").unwrap();

        let options = DaemonOptions {
            home: temp.path().to_path_buf(),
            daemon_path: expected.to_string_lossy().to_string(),
        };
        let missing = status_with_options(&options).unwrap();
        assert!(!missing.installed);
        assert!(!missing.configured);

        let old = temp.path().join("old").join("whileitthinksd");
        fs::create_dir_all(old.parent().unwrap()).unwrap();
        fs::write(&old, "").unwrap();
        let stale_options = DaemonOptions {
            home: temp.path().to_path_buf(),
            daemon_path: old.to_string_lossy().to_string(),
        };
        let plist_path = launch_agent_plist_path(temp.path());
        fs::create_dir_all(plist_path.parent().unwrap()).unwrap();
        fs::write(&plist_path, launch_agent_plist(&stale_options)).unwrap();

        let stale = status_with_options(&options).unwrap();
        assert!(stale.installed);
        assert!(!stale.configured);
        assert_eq!(
            stale.stale_daemon_paths,
            vec![old.to_string_lossy().to_string()]
        );
    }
}
