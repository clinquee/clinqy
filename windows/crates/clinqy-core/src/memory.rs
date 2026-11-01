//! Durable facts Clinqy learns about the user, one per line in `~/.config/clinqy/memory.md` (the same file and
//! format as the Mac app, hand-editable). A line can carry a scope tag for know-how that matters in one place:
//! "[site:docs.google.com] date fields are dd/mm/yyyy", "[app:Settings] search finds any setting".
//! Retrieval: the profile always, notes for the site or app in use, then BM25 over the rest (with light stemming).

use parking_lot::Mutex;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::SystemTime;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Scope {
    /// "site" or "app"
    pub kind: String,
    pub name: String,
}

impl Scope {
    pub fn new(kind: &str, name: &str) -> Scope {
        let kind = kind.trim().to_lowercase();
        let name = if kind == "site" { bare_host(name) } else { name.trim().to_string() };
        Scope { kind, name }
    }

    /// "site:wellfound.com" / "app:Settings" (as the model writes it).
    pub fn parse(raw: &str) -> Option<Scope> {
        let (kind, name) = raw.split_once(':')?;
        let kind = kind.trim().to_lowercase();
        let name = name.trim();
        if !["site", "app"].contains(&kind.as_str()) || name.is_empty() {
            return None;
        }
        Some(Scope::new(&kind, name))
    }

    pub fn tag(&self) -> String {
        format!("[{}:{}]", self.kind, self.name)
    }

    /// The site or app this is about is the one in use.
    pub fn matches(&self, app: Option<&str>, host: Option<&str>) -> bool {
        if self.kind == "site" {
            let Some(host) = host.map(bare_host).filter(|h| !h.is_empty()) else { return false };
            return host == self.name || host.ends_with(&format!(".{}", self.name)) || self.name.ends_with(&format!(".{host}"));
        }
        app.map(|a| squash(a) == squash(&self.name)).unwrap_or(false)
    }

    /// The request names it ("open settings", "apply on wellfound").
    pub fn mentioned(&self, text: &str) -> bool {
        let t = text.to_lowercase();
        if self.kind == "site" {
            if t.contains(&self.name) {
                return true;
            }
            let parts: Vec<&str> = self.name.split('.').collect();
            if parts.len() < 2 {
                return false;
            }
            let core = parts[parts.len() - 2];
            return core.len() >= 4 && !["google", "apple", "microsoft", "amazon"].contains(&core) && has_word(core, &t);
        }
        let sq = squash(&self.name);
        has_word(&self.name.to_lowercase(), &t) || (sq.len() >= 5 && squash(&t).contains(&sq))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Fact {
    pub text: String,
    pub scope: Option<Scope>,
    pub tagged: bool,
}

impl Fact {
    pub fn line(&self) -> String {
        match (&self.scope, self.tagged) {
            (Some(s), true) => format!("{} {}", s.tag(), self.text),
            _ => self.text.clone(),
        }
    }
}

pub fn path() -> PathBuf {
    crate::paths::config_dir().join("memory.md")
}

fn history_path() -> PathBuf {
    crate::paths::config_dir().join("memory.history.jsonl")
}

fn meta_path() -> PathBuf {
    crate::paths::config_dir().join("memory.meta.json")
}

struct Loaded {
    stamp: Option<SystemTime>,
    size: u64,
    entries: Vec<Fact>,
}

static LOADED: Mutex<Option<Loaded>> = Mutex::new(None);

pub fn parse(text: &str) -> Vec<Fact> {
    static BULLET: OnceLock<Regex> = OnceLock::new();
    static TAG: OnceLock<Regex> = OnceLock::new();
    static HEADING: OnceLock<Regex> = OnceLock::new();
    let bullet = BULLET.get_or_init(|| Regex::new(r"^(?:[-*•+]|\d{1,3}[.)])\s+(?:\[[ xX]\]\s+)?").unwrap());
    let tag = TAG.get_or_init(|| Regex::new(r"(?i)^\[(site|app)\s*:\s*([^\]]+)\]\s*").unwrap());
    let heading = HEADING.get_or_init(|| Regex::new(r"^#{1,6}\s").unwrap());
    text.lines()
        .filter_map(|raw| {
            let mut line = raw.trim().trim_start_matches('\u{feff}').to_string();
            if heading.is_match(&line) || line.starts_with("<!--") {
                return None;
            }
            if let Some(m) = bullet.find(&line) {
                line = line[m.end()..].to_string();
            }
            let line = line.trim_matches(|c| c == '-' || c == ' ').to_string();
            if line.is_empty() {
                return None;
            }
            if let Some(c) = tag.captures(&line) {
                let rest = line[c.get(0).unwrap().end()..].trim().to_string();
                if !rest.is_empty() {
                    return Some(Fact { text: rest, scope: Some(Scope::new(&c[1], &c[2])), tagged: true });
                }
            }
            Some(Fact { text: line, scope: None, tagged: false })
        })
        .collect()
}

pub fn entries() -> Vec<Fact> {
    let p = path();
    let meta = std::fs::metadata(&p).ok();
    let stamp = meta.as_ref().and_then(|m| m.modified().ok());
    let size = meta.map(|m| m.len()).unwrap_or(0);
    let mut l = LOADED.lock();
    if let Some(l) = l.as_ref() {
        if l.stamp == stamp && l.size == size {
            return l.entries.clone();
        }
    }
    let entries = parse(&std::fs::read_to_string(&p).unwrap_or_default());
    *l = Some(Loaded { stamp, size, entries: entries.clone() });
    entries
}

pub fn facts() -> Vec<String> {
    entries().into_iter().map(|f| f.text).collect()
}

fn write(lines: &[String]) {
    let body: String = lines.iter().map(|l| format!("- {l}\n")).collect();
    let p = path();
    let tmp = p.with_extension("md.tmp");
    if std::fs::write(&tmp, body).is_ok() {
        let _ = std::fs::rename(&tmp, &p);
    }
    *LOADED.lock() = None;
}

/// Saves a fact (moved to the end if it was there already, so it reads as the newest).
pub fn add(fact: &str, scope: Option<Scope>) {
    let text = fact.trim().to_string();
    if text.is_empty() {
        return;
    }
    let all = entries();
    let kept = scope.or_else(|| all.iter().find(|f| f.text == text && f.tagged).and_then(|f| f.scope.clone()));
    let mut lines: Vec<String> = all.iter().filter(|f| f.text != text).map(|f| f.line()).collect();
    lines.push(Fact { text: text.clone(), tagged: kept.is_some(), scope: kept }.line());
    write(&lines);
    touch(&[text]);
}

pub fn update(old: &str, new: &str) -> bool {
    let text = new.trim();
    let all = entries();
    let Some(i) = all.iter().position(|f| f.text == old) else { return false };
    if text.is_empty() {
        return false;
    }
    let fact = Fact { text: text.to_string(), scope: if all[i].tagged { all[i].scope.clone() } else { None }, tagged: all[i].tagged };
    let lines: Vec<String> = all
        .iter()
        .enumerate()
        .filter_map(|(j, f)| {
            if j == i {
                Some(fact.line())
            } else if f.text == text {
                None
            } else {
                Some(f.line())
            }
        })
        .collect();
    write(&lines);
    record(old, Some(text), "updated");
    true
}

pub fn remove(fact: &str, why: Option<&str>) -> bool {
    let all = entries();
    if !all.iter().any(|f| f.text == fact) {
        return false;
    }
    let lines: Vec<String> = all.iter().filter(|f| f.text != fact).map(|f| f.line()).collect();
    write(&lines);
    record(fact, None, why.unwrap_or("removed"));
    true
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Change {
    pub at: String,
    pub old: String,
    pub new: Option<String>,
    pub why: String,
}

fn record(old: &str, new: Option<&str>, why: &str) {
    let c = Change { at: chrono::Utc::now().to_rfc3339(), old: old.into(), new: new.map(String::from), why: why.into() };
    if let Ok(line) = serde_json::to_string(&c) {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(history_path()) {
            let _ = writeln!(f, "{line}");
        }
    }
}

pub fn history() -> Vec<Change> {
    std::fs::read_to_string(history_path()).unwrap_or_default().lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

/// Earlier wordings of a fact, newest first.
pub fn earlier(fact: &str, changes: &[Change]) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    let mut current = fact.to_string();
    while out.len() < 3 {
        let Some(c) = changes.iter().rev().find(|c| c.new.as_deref() == Some(current.as_str()) && !out.contains(&c.old) && c.old != fact)
        else {
            break;
        };
        out.push(c.old.clone());
        current = c.old.clone();
    }
    out
}

/// Dropped or replaced lines matching the query.
pub fn search_history(query: &str) -> Vec<Change> {
    let want: HashSet<String> = words(query).iter().map(|w| stem(w)).collect();
    if want.is_empty() {
        return vec![];
    }
    history()
        .into_iter()
        .rev()
        .filter(|c| {
            let mine: HashSet<String> = words(&c.old).iter().map(|w| stem(w)).collect();
            mine.intersection(&want).count() as f64 >= (want.len() as f64 * 0.5).max(1.0)
        })
        .take(5)
        .collect()
}

// MARK: - Usage (facts that get used rank higher)

fn touch(facts: &[String]) {
    let mut meta: HashMap<String, (u32, i64)> =
        std::fs::read_to_string(meta_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    let now = chrono::Utc::now().timestamp();
    for f in facts {
        let e = meta.entry(hash(f)).or_insert((0, now));
        e.0 += 1;
        e.1 = now;
    }
    if let Ok(t) = serde_json::to_string(&meta) {
        let _ = std::fs::write(meta_path(), t);
    }
}

pub fn note_used(facts: &[String]) {
    if !facts.is_empty() {
        touch(facts);
    }
}

fn usage() -> HashMap<String, (u32, i64)> {
    std::fs::read_to_string(meta_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn hash(s: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.as_bytes() {
        h = (h ^ *b as u64).wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

/// Of the facts shown this run, those its output actually used (a distinctive word of the fact shows up).
pub fn used(among: &HashSet<String>, output: &str, apps: &HashSet<String>, hosts: &HashSet<String>) -> Vec<String> {
    let out = output.to_lowercase();
    let entries = entries();
    among
        .iter()
        .filter(|f| {
            if let Some(e) = entries.iter().find(|e| &e.text == *f) {
                if let Some(s) = &e.scope {
                    return apps.iter().any(|a| s.matches(Some(a), None)) || hosts.iter().any(|h| s.matches(None, Some(h)));
                }
            }
            details(f).iter().any(|d| out.contains(&d.to_lowercase()))
        })
        .cloned()
        .collect()
}

// MARK: - Retrieval

fn profile_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(?i)^(?:[\p{L}\p{N}-]+'s\s+)?(?:(?:personal|college|school|work|primary|full|current|home|default|preferred)\s+)?(?:name|full name|phone(?: number)?|mobile(?: number)?|e-?mail(?: address)?|gmail|browser|gender|date of birth|birthday|dob|roll number|cgpa|gpa|github|linkedin|portfolio|website|resume|cv|tech stack|skills|college|university|degree|address|location|city|nationality|pronouns)\b(?:\s*\([^)]*\))?(?:\s+for\s+\w+)?(?:\s+[^\s:]+)?\s*(?:\bis\b|\bare\b|:|=)|^(?:the user is|user is|student at|studies at|lives in|based in|born|works at|messages people)\b").unwrap()
    })
}

/// Profile facts (who the user is and how to reach them) always go along.
pub fn is_profile(fact: &str) -> bool {
    profile_re().is_match(fact)
}

pub fn scoped(app: Option<&str>, host: Option<&str>) -> Vec<String> {
    entries().into_iter().filter(|f| f.scope.as_ref().map(|s| s.matches(app, host)).unwrap_or(false)).map(|f| f.text).collect()
}

const STOP: &[&str] = &[
    "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "was", "be", "it", "this", "that", "my", "me", "i",
    "you", "your", "at", "by", "from", "as", "can", "please", "do", "what", "whats", "who", "where", "when", "how", "which", "open", "go",
    "use", "get", "set", "show", "find", "tell", "about", "into", "up", "then", "now", "just", "also",
];

pub fn words(text: &str) -> Vec<String> {
    text.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() >= 2 && !STOP.contains(w)).map(String::from).collect()
}

pub fn stem(w: &str) -> String {
    for suffix in ["ings", "ing", "edly", "ies", "ed", "es", "s", "ly"] {
        if w.len() > suffix.len() + 2 && w.ends_with(suffix) {
            let base = &w[..w.len() - suffix.len()];
            return if suffix == "ies" { format!("{base}y") } else { base.to_string() };
        }
    }
    w.to_string()
}

/// Emails, links, numbers and capitalised names in a fact: what a rewrite must keep.
pub fn details(fact: &str) -> Vec<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = R.get_or_init(|| Regex::new(r"[\w.+-]+@[\w-]+\.[\w.]+|https?://\S+|\+?\d[\d\s-]{3,}\d|\b[A-Z][\w'’-]{2,}").unwrap());
    r.find_iter(fact).map(|m| m.as_str().trim().to_string()).collect()
}

struct RankIndex {
    facts: Vec<String>,
    docs: Vec<Vec<String>>,
    df: HashMap<String, f64>,
    avg: f64,
}
impl RankIndex {
    fn new(facts: &[String]) -> Self {
        let docs: Vec<Vec<String>> = facts.iter().map(|f| words(f).iter().map(|w| stem(w)).collect()).collect();
        let avg = docs.iter().map(Vec::len).sum::<usize>() as f64 / docs.len().max(1) as f64;
        let mut df = HashMap::new();
        for doc in &docs {
            for word in doc.iter().collect::<HashSet<_>>() {
                *df.entry(word.clone()).or_default() += 1.0;
            }
        }
        Self { facts: facts.to_vec(), docs, df, avg }
    }
}
fn cached_usage() -> HashMap<String, (u32, i64)> {
    type Usage = (Option<SystemTime>, u64, HashMap<String, (u32, i64)>);
    static CACHE: Mutex<Option<Usage>> = Mutex::new(None);
    let meta = std::fs::metadata(meta_path()).ok();
    let stamp = meta.as_ref().and_then(|m| m.modified().ok());
    let size = meta.map(|m| m.len()).unwrap_or_default();
    let mut cache = CACHE.lock();
    if cache.as_ref().map(|(s, n, _)| (*s, *n)) != Some((stamp, size)) {
        *cache = Some((stamp, size, usage()));
    }
    cache.as_ref().unwrap().2.clone()
}

/// BM25 ranking of `facts` for `query`, best first, with scores.
fn rank(query: &str, facts: &[String]) -> Vec<(usize, f64)> {
    let q: Vec<String> = words(query).iter().map(|w| stem(w)).collect::<HashSet<_>>().into_iter().collect();
    if q.is_empty() || facts.is_empty() {
        return vec![];
    }
    // Reuse tokenization/document frequencies across every label on the same page.
    static INDEX: Mutex<Option<RankIndex>> = Mutex::new(None);
    let mut cached = INDEX.lock();
    if cached.as_ref().map(|i| i.facts.as_slice()) != Some(facts) {
        *cached = Some(RankIndex::new(facts));
    }
    let index = cached.as_ref().unwrap();
    let (docs, df, avg) = (&index.docs, &index.df, index.avg);
    let n = docs.len() as f64;
    let use_ = cached_usage();
    let (k1, b) = (1.2, 0.75);
    let mut scored: Vec<(usize, f64)> = docs
        .iter()
        .enumerate()
        .filter_map(|(i, d)| {
            let mut s = 0.0;
            for t in &q {
                let tf = d.iter().filter(|w| *w == t).count() as f64;
                if tf == 0.0 {
                    // Prefix match for longer words ("passport" ~ "passports" handled by stem; "linked" ~ "linkedin").
                    if t.len() >= 5 && d.iter().any(|w| w.starts_with(t.as_str()) || t.starts_with(w.as_str()) && w.len() >= 5) {
                        s += 0.4;
                    }
                    continue;
                }
                let idf = ((n - df.get(t.as_str()).copied().unwrap_or(0.0) + 0.5) / (df.get(t.as_str()).copied().unwrap_or(0.0) + 0.5)
                    + 1.0)
                    .ln();
                s += idf * tf * (k1 + 1.0) / (tf + k1 * (1.0 - b + b * d.len() as f64 / avg.max(1.0)));
            }
            if s <= 0.0 {
                return None;
            }
            // A little credit for facts that keep getting used.
            if let Some((count, _)) = use_.get(&hash(&facts[i])) {
                s *= 1.0 + (*count as f64).ln_1p() * 0.08;
            }
            Some((i, s))
        })
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let strongest = scored.first().map(|s| s.1).unwrap_or(0.0);
    scored.retain(|s| s.1 >= strongest * 0.3);
    scored
}

/// The facts worth sending for a request: the profile, notes for the app or site in use (or named), and the best
/// matches among the rest; everything while memory is small. Returns (facts, how many were left out).
pub fn relevant(context: &str, app: Option<&str>, host: Option<&str>, limit: usize) -> (Vec<String>, usize) {
    let all = entries();
    if all.iter().map(|f| f.line().len()).sum::<usize>() <= 16_000 {
        let (p, r): (Vec<_>, Vec<_>) = all.into_iter().map(|f| f.text).partition(|t| is_profile(t));
        return (p.into_iter().chain(r).collect(), 0);
    }
    let profile: Vec<String> = all.iter().filter(|f| is_profile(&f.text)).map(|f| f.text.clone()).collect();
    let rest: Vec<&Fact> = all.iter().filter(|f| !is_profile(&f.text)).collect();
    let here: Vec<String> = rest
        .iter()
        .filter(|f| f.scope.as_ref().map(|s| s.matches(app, host) || s.mentioned(context)).unwrap_or(false))
        .map(|f| f.text.clone())
        .collect();
    let others: Vec<String> = rest.iter().filter(|f| !here.contains(&f.text)).map(|f| f.text.clone()).collect();
    let room = limit.saturating_sub(profile.len() + here.len());
    let ranked: Vec<String> = rank(context, &others).into_iter().take(room).map(|(i, _)| others[i].clone()).collect();
    let chosen: Vec<String> = profile.into_iter().chain(here).chain(ranked).collect();
    let omitted = all.len().saturating_sub(chosen.len());
    (chosen, omitted)
}

/// Facts that answer a page's fields (labels), not already shown.
pub fn for_page(labels: &[String], excluding: &HashSet<String>, app: Option<&str>, host: Option<&str>, limit: usize) -> Vec<String> {
    let all: Vec<String> = entries()
        .into_iter()
        .filter(|f| f.scope.as_ref().map(|s| s.matches(app, host)).unwrap_or(true))
        .map(|f| f.text)
        .filter(|t| !excluding.contains(t))
        .collect();
    if all.is_empty() {
        return vec![];
    }
    let mut best: HashMap<usize, f64> = HashMap::new();
    for label in labels.iter().filter(|l| l.trim().len() >= 3).take(40) {
        let want = words(label).len().max(1) as f64;
        if let Some((i, score)) = rank(label, &all).into_iter().next() {
            // Credit a fact by how much of the label it covers.
            let have: HashSet<String> = words(&all[i]).iter().map(|w| stem(w)).collect();
            let covered = words(label).iter().filter(|w| have.contains(&stem(w))).count() as f64;
            let s = score * (covered / want);
            if covered > 0.0 {
                let e = best.entry(i).or_default();
                *e = e.max(s);
            }
        }
    }
    let mut v: Vec<(usize, f64)> = best.into_iter().filter(|(_, s)| *s >= 1.0).collect();
    v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    v.into_iter().take(limit).map(|(i, _)| all[i].clone()).collect()
}

pub fn search(query: &str) -> Vec<String> {
    let all = facts();
    rank(query, &all).into_iter().take(15).map(|(i, _)| all[i].clone()).collect()
}

/// An existing fact that says nearly the same thing.
pub fn near_duplicate(fact: &str) -> Option<String> {
    let mine: HashSet<String> = words(fact).iter().map(|w| stem(w)).collect();
    if mine.is_empty() {
        return None;
    }
    facts().into_iter().find(|other| {
        let theirs: HashSet<String> = words(other).iter().map(|w| stem(w)).collect();
        mine.intersection(&theirs).count() as f64 / mine.union(&theirs).count().max(1) as f64 >= 0.8
    })
}

pub fn bare_host(raw: &str) -> String {
    let mut h = raw.trim().to_lowercase();
    if let Some(i) = h.find("://") {
        h = h[i + 3..].to_string();
    }
    if let Some(i) = h.find('/') {
        h.truncate(i);
    }
    h.strip_prefix("www.").map(String::from).unwrap_or(h)
}

pub fn squash(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect()
}

pub fn has_word(word: &str, text: &str) -> bool {
    let t = text.to_lowercase();
    let w = word.to_lowercase();
    let mut start = 0;
    while let Some(i) = t[start..].find(&w) {
        let a = start + i;
        let b = a + w.len();
        let before = t[..a].chars().last().map(|c| c.is_alphanumeric()).unwrap_or(false);
        let after = t[b..].chars().next().map(|c| c.is_alphanumeric()).unwrap_or(false);
        if !before && !after {
            return true;
        }
        start = a + w.len().max(1);
        if start >= t.len() {
            break;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tags_and_bullets() {
        let f = parse("# Memory\n- Name is Amrit\n* [site:www.docs.google.com] dates are dd/mm\n1. [app:Settings] search finds things\n");
        assert_eq!(f.len(), 3);
        assert_eq!(f[1].scope.as_ref().unwrap().name, "docs.google.com");
        assert!(f[1].scope.as_ref().unwrap().matches(None, Some("https://docs.google.com/x")));
        assert!(f[2].scope.as_ref().unwrap().matches(Some("Settings"), None));
    }

    #[test]
    fn profile_facts() {
        assert!(is_profile("Phone number is +91 98450 12345"));
        assert!(is_profile("Student at IIT Delhi"));
        assert!(!is_profile("LinkedIn feed posts sometimes repost"));
    }

    #[test]
    fn ranks_by_words() {
        let facts =
            vec!["Mom's WhatsApp chat is 'Mom'".to_string(), "Prefers aisle seats on flights".to_string(), "Uses Chrome".to_string()];
        let r = rank("book flights with an aisle seat", &facts);
        assert_eq!(r[0].0, 1);
    }

    #[test]
    fn words_match() {
        assert!(has_word("find my", "open find my please"));
        assert!(!has_word("lock", "clock"));
    }
}
