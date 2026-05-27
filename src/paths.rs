use std::env;
use std::path::PathBuf;

pub const APP_NAME: &str = "WhileItThinks";
pub const SOCKET_NAME: &str = "whileitthinks.sock";
pub const HTTP_ADDR: &str = "127.0.0.1:47328";

pub fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn app_support_dir() -> PathBuf {
    home_dir()
        .join("Library")
        .join("Application Support")
        .join(APP_NAME)
}

pub fn socket_path() -> PathBuf {
    if let Some(path) = env::var_os("WHILEITTHINKS_SOCKET") {
        return PathBuf::from(path);
    }
    app_support_dir().join(SOCKET_NAME)
}

pub fn http_addr() -> String {
    env::var("WHILEITTHINKS_HTTP_ADDR").unwrap_or_else(|_| HTTP_ADDR.to_string())
}

pub fn database_path() -> PathBuf {
    app_support_dir().join("events.sqlite3")
}

pub fn actions_log_path() -> PathBuf {
    app_support_dir().join("actions.jsonl")
}

pub fn default_installed_hook_path() -> String {
    format!("/Applications/WhileItThinks.app/Contents/MacOS/whileitthinks-hook")
}
