//! Where Clinqy keeps things. Settings and memory live where the Mac app keeps them (`~/.config/clinqy`), so the
//! same env file, memory and job profile work on both; app data and logs follow Windows conventions.

use std::path::PathBuf;
use std::sync::OnceLock;

fn env_dir(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).map(PathBuf::from).filter(|p| !p.as_os_str().is_empty())
}

/// The user's home folder (`%USERPROFILE%`).
pub fn home() -> PathBuf {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| env_dir("USERPROFILE").or_else(|| env_dir("HOME")).unwrap_or_else(|| PathBuf::from("."))).clone()
}

/// `~/.config/clinqy`: env (settings), memory.md, the CLI token. Shared with the Mac app's layout.
pub fn config_dir() -> PathBuf {
    let dir = env_dir("CLINQY_CONFIG_DIR").unwrap_or_else(|| home().join(".config").join("clinqy"));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// `%APPDATA%\Clinqy`: history, workflows, skills, click hints (the Mac's Application Support/Clinqy).
pub fn data_dir() -> PathBuf {
    let dir = env_dir("CLINQY_DATA_DIR")
        .unwrap_or_else(|| env_dir("APPDATA").unwrap_or_else(|| home().join("AppData").join("Roaming")).join("Clinqy"));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// `%LOCALAPPDATA%\Clinqy\Logs`: agent.log and runs.jsonl (the Mac's ~/Library/Logs/Clinqy).
pub fn log_dir() -> PathBuf {
    let dir = env_dir("CLINQY_LOG_DIR").unwrap_or_else(|| local_dir().join("Logs"));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// `%LOCALAPPDATA%\Clinqy`: models and caches that needn't roam with the profile.
pub fn local_dir() -> PathBuf {
    let dir = env_dir("LOCALAPPDATA").unwrap_or_else(|| home().join("AppData").join("Local")).join("Clinqy");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

pub fn env_file() -> PathBuf {
    config_dir().join("env")
}

pub fn agent_log() -> PathBuf {
    log_dir().join("agent.log")
}

/// Expands `~`, `$HOME` and `%VAR%` in a path the model wrote, and accepts forward slashes.
pub fn expand(path: &str) -> PathBuf {
    let mut p = path.trim().trim_matches('"').to_string();
    if p == "~" {
        return home();
    }
    if let Some(rest) = p.strip_prefix("~/").or_else(|| p.strip_prefix("~\\")) {
        p = format!("{}\\{}", home().display(), rest);
    }
    for var in ["$HOME", "${HOME}", "$env:USERPROFILE", "%USERPROFILE%", "%HOMEPATH%"] {
        if p.contains(var) {
            p = p.replace(var, &home().display().to_string());
        }
    }
    // Any other %VAR%.
    let re = regex::Regex::new(r"%([A-Za-z_][A-Za-z0-9_]*)%").unwrap();
    p = re.replace_all(&p, |c: &regex::Captures| std::env::var(&c[1]).unwrap_or_else(|_| c[0].to_string())).into_owned();
    PathBuf::from(p.replace('/', "\\"))
}

/// A path as shown to the model and the user: `~\Downloads\a.pdf` rather than the full profile path.
pub fn display(path: &std::path::Path) -> String {
    let home = home();
    match path.strip_prefix(&home) {
        Ok(rest) => format!("~\\{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_home_forms() {
        let h = home().display().to_string().replace('/', "\\");
        assert_eq!(expand("~/Downloads/a.pdf").display().to_string(), format!("{h}\\Downloads\\a.pdf"));
        assert_eq!(expand("$HOME\\x").display().to_string(), format!("{h}\\x"));
        assert_eq!(expand("\"C:/a b/c.txt\"").display().to_string(), "C:\\a b\\c.txt");
    }
}
