//! Settings: the process environment first, then `~/.config/clinqy/env` (KEY=VALUE lines), the same file and
//! format as on the Mac. The file is re-read when it changes, so edits apply without a restart.

use parking_lot::Mutex;
use std::collections::HashMap;
use std::time::SystemTime;

struct Cache {
    stamp: Option<SystemTime>,
    values: HashMap<String, String>,
}

static CACHE: Mutex<Option<Cache>> = Mutex::new(None);

pub fn parse(text: &str) -> HashMap<String, String> {
    let mut values = HashMap::new();
    for line in text.lines() {
        let trimmed = line.trim().trim_start_matches('\u{feff}');
        if trimmed.starts_with('#') {
            continue;
        }
        let Some(eq) = trimmed.find('=') else { continue };
        let key = trimmed[..eq].trim();
        let key = key.strip_prefix("export ").unwrap_or(key).trim();
        if key.is_empty() {
            continue;
        }
        let value = trimmed[eq + 1..].trim().trim_matches(|c| c == '"' || c == '\'' || c == ' ');
        values.insert(key.to_string(), value.to_string());
    }
    values
}

fn file_values() -> HashMap<String, String> {
    let path = crate::paths::env_file();
    let stamp = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
    let mut cache = CACHE.lock();
    if let Some(c) = cache.as_ref() {
        if c.stamp == stamp {
            return c.values.clone();
        }
    }
    let values = std::fs::read_to_string(&path).map(|t| parse(&t)).unwrap_or_default();
    *cache = Some(Cache { stamp, values: values.clone() });
    values
}

/// A setting, or None when it's unset or empty.
pub fn value(key: &str) -> Option<String> {
    if let Ok(v) = std::env::var(key) {
        if !v.is_empty() {
            return Some(v);
        }
    }
    file_values().get(key).filter(|v| !v.is_empty()).cloned()
}

/// On unless set to off/0/no/false.
pub fn on(key: &str, default: bool) -> bool {
    match value(key).map(|v| v.to_lowercase()) {
        Some(v) if ["off", "0", "no", "false"].contains(&v.as_str()) => false,
        Some(v) if ["on", "1", "yes", "true"].contains(&v.as_str()) => true,
        _ => default,
    }
}

/// Saves a setting in the env file (see `with_setting`).
pub fn set(key: &str, value: &str) -> std::io::Result<()> {
    let path = crate::paths::env_file();
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(&path, with_setting(&text, key, value))?;
    *CACHE.lock() = None;
    Ok(())
}

/// `text` with `key` set: its line (commented-out or not) replaced, or one appended; an empty value removes it.
pub fn with_setting(text: &str, key: &str, value: &str) -> String {
    let line = format!("{key}={value}");
    let mut found = false;
    let mut out: Vec<String> = vec![];
    for l in text.lines() {
        let t = l.trim().trim_start_matches('#').trim();
        let t = t.strip_prefix("export ").unwrap_or(t);
        if t.contains('=') && t.split('=').next().map(str::trim) == Some(key) {
            if !found && !value.is_empty() {
                out.push(line.clone());
            }
            found = true;
            continue;
        }
        out.push(l.to_string());
    }
    if !found && !value.is_empty() {
        out.push(line);
    }
    out.join("\n") + "\n"
}

#[cfg(test)]
mod tests {
    #[test]
    fn parses_env_lines() {
        let v = super::parse("# c\nA=1\n B = \"two\" \nexport C='x'\nnoeq\n=bad");
        assert_eq!(v["A"], "1");
        assert_eq!(v["B"], "two");
        assert_eq!(v["C"], "x");
        assert_eq!(v.len(), 3);
    }

    #[test]
    fn sets_settings_in_place() {
        let t = "# Clinqy\nPROVIDER=claude-cli\n# VOICE_LANGUAGE=en\nHOTKEY=ctrl+alt\n";
        let out = super::with_setting(t, "VOICE_LANGUAGE", "hinglish");
        assert_eq!(out, "# Clinqy\nPROVIDER=claude-cli\nVOICE_LANGUAGE=hinglish\nHOTKEY=ctrl+alt\n");
        assert_eq!(super::parse(&out)["VOICE_LANGUAGE"], "hinglish");
        assert!(super::with_setting(&out, "NEW", "1").ends_with("NEW=1\n"));
        assert!(!super::with_setting(&out, "VOICE_LANGUAGE", "").contains("VOICE_LANGUAGE"));
    }
}
