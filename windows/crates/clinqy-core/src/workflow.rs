//! Deterministic workflows (what a run did, replayed without a model; healed by the model only when a step
//! breaks), the cache of runs that worked (offered as a hint, or replayed outright), and the router that decides
//! before the model whether a saved workflow already does a request. Same files and shapes as the Mac app.

use crate::history::Entry;
use parking_lot::Mutex;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Default)]
pub struct Target {
    /// "web" | "ax" (an app control; the Mac's name for it)
    pub kind: String,
    pub role: String,
    pub label: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Default)]
pub struct WorkflowStep {
    pub action: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keys: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dir: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub script: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub submit: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<Target>,
}

impl WorkflowStep {
    pub fn new(action: &str) -> WorkflowStep {
        WorkflowStep { action: action.into(), ..Default::default() }
    }

    pub fn summary(&self) -> String {
        let t = self.target.as_ref().map(|t| format!("{} “{}”", t.role, t.label.chars().take(50).collect::<String>())).unwrap_or_default();
        let text = self.text.clone().unwrap_or_default().chars().take(40).collect::<String>();
        match self.action.as_str() {
            "open_app" => format!("Open {}", self.name.as_deref().unwrap_or("?")),
            "open_url" => format!("Go to {}", self.url.as_deref().unwrap_or("?")),
            "click" => format!("Click {t}"),
            "type" => format!(
                "Type “{text}”{}{}",
                if t.is_empty() { String::new() } else { format!(" into {t}") },
                if self.submit == Some(true) { " ⏎" } else { "" }
            ),
            "key" => format!("Press {}", self.keys.as_deref().unwrap_or("?")),
            "scroll" => format!("Scroll {}", self.dir.as_deref().unwrap_or("down")),
            "shell" | "applescript" => "Run a script".into(),
            "wait" => format!("Wait {} ms", self.ms.unwrap_or(0)),
            "expect" => format!("Expect “{}”", self.text.clone().unwrap_or_default().chars().take(60).collect::<String>()),
            other => other.into(),
        }
    }

    /// The step as an agent action, {parameters} filled in; the target is resolved to an id by the caller.
    pub fn to_action(&self, params: &HashMap<String, String>, id: Option<String>) -> Map<String, Value> {
        let fill = |s: &Option<String>| {
            s.as_ref().map(|s| {
                let mut s = s.clone();
                for (k, v) in params {
                    s = s.replace(&format!("{{{k}}}"), v);
                }
                s
            })
        };
        let mut a = Map::new();
        a.insert("do".into(), json!(if self.action == "applescript" { "shell" } else { self.action.as_str() }));
        if let Some(v) = fill(&self.name) {
            a.insert("name".into(), json!(v));
        }
        if let Some(v) = fill(&self.url) {
            a.insert("url".into(), json!(v));
        }
        if let Some(v) = fill(&self.text) {
            a.insert("text".into(), json!(v));
        }
        if let Some(v) = &self.keys {
            a.insert("keys".into(), json!(v));
        }
        if let Some(v) = &self.dir {
            a.insert("dir".into(), json!(v));
        }
        if let Some(v) = fill(&self.script) {
            a.insert("cmd".into(), json!(v));
        }
        if let Some(v) = self.ms {
            a.insert("ms".into(), json!(v));
        }
        if let Some(v) = self.submit {
            a.insert("submit".into(), json!(v));
        }
        if let Some(id) = id {
            a.insert("id".into(), json!(id));
        }
        a
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Workflow {
    #[serde(default = "new_id")]
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub params: Vec<String>,
    pub steps: Vec<WorkflowStep>,
    #[serde(default = "now")]
    pub created: String,
    /// "HH:mm" to run every day.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schedule: Option<String>,
    #[serde(default, rename = "lastScheduledRun", skip_serializing_if = "Option::is_none")]
    pub last_scheduled_run: Option<String>,
    #[serde(default, rename = "healedAt", skip_serializing_if = "Option::is_none")]
    pub healed_at: Option<String>,
    #[serde(default)]
    pub runs: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub defaults: Option<HashMap<String, String>>,
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}

impl Workflow {
    pub fn new(name: &str, summary: &str, steps: Vec<WorkflowStep>) -> Workflow {
        Workflow {
            id: new_id(),
            name: name.into(),
            summary: summary.into(),
            params: vec![],
            steps,
            created: now(),
            schedule: None,
            last_scheduled_run: None,
            healed_at: None,
            runs: 0,
            defaults: None,
        }
    }

    /// From a finished run: typed text becomes a named parameter (the field's label), defaulting to what was typed.
    pub fn from_entry(entry: &Entry) -> Option<Workflow> {
        if entry.requires_fresh_work {
            return None;
        }
        let mut steps = entry.trace.clone().filter(|t| !t.is_empty())?;
        let mut params: Vec<String> = vec![];
        let mut defaults = HashMap::new();
        for s in steps.iter_mut().filter(|s| s.action == "type") {
            let Some(text) = s.text.clone().filter(|t| !t.is_empty()) else { continue };
            let mut key = s.target.as_ref().map(|t| t.label.trim().to_string()).unwrap_or_else(|| "text".into());
            if key.is_empty() {
                key = "text".into();
            }
            let (mut unique, mut n) = (key.clone(), 2);
            while params.contains(&unique) {
                unique = format!("{key} {n}");
                n += 1;
            }
            params.push(unique.clone());
            defaults.insert(unique.clone(), text);
            s.text = Some(format!("{{{unique}}}"));
        }
        let mut w = Workflow::new(&entry.request.chars().take(60).collect::<String>(), &entry.answer, steps);
        w.params = params;
        w.defaults = Some(defaults);
        Some(w)
    }
}

pub struct Workflows {
    all: Mutex<Vec<Workflow>>,
}

fn store_path(name: &str) -> std::path::PathBuf {
    crate::paths::data_dir().join(name)
}

fn write_json<T: Serialize>(name: &str, value: &T) {
    if let Ok(t) = serde_json::to_string_pretty(value) {
        let p = store_path(name);
        let tmp = p.with_extension("tmp");
        if std::fs::write(&tmp, t).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }
}

pub fn workflows() -> &'static Workflows {
    static W: OnceLock<Workflows> = OnceLock::new();
    W.get_or_init(|| Workflows {
        all: Mutex::new(
            std::fs::read_to_string(store_path("workflows.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default(),
        ),
    })
}

impl Workflows {
    pub fn all(&self) -> Vec<Workflow> {
        self.all.lock().clone()
    }
    pub fn add(&self, w: Workflow) {
        let mut a = self.all.lock();
        a.insert(0, w);
        write_json("workflows.json", &*a);
    }
    pub fn remove(&self, id: &str) {
        let mut a = self.all.lock();
        a.retain(|w| w.id != id);
        write_json("workflows.json", &*a);
    }
    pub fn update(&self, w: Workflow) {
        let mut a = self.all.lock();
        if let Some(i) = a.iter().position(|x| x.id == w.id) {
            a[i] = w;
            write_json("workflows.json", &*a);
        }
    }
    pub fn named(&self, name: &str) -> Option<Workflow> {
        let a = self.all.lock();
        let n = name.to_lowercase();
        a.iter().find(|w| w.name.to_lowercase() == n).or_else(|| a.iter().find(|w| w.name.to_lowercase().contains(&n))).cloned()
    }
}

// MARK: - Router

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).unwrap())
}

/// Lowercased, spaces collapsed, filler ("please", "hey clinqy", "can you") dropped.
pub fn normalize(s: &str) -> String {
    static WS: OnceLock<Regex> = OnceLock::new();
    static FILL: OnceLock<Regex> = OnceLock::new();
    static TAIL: OnceLock<Regex> = OnceLock::new();
    let t = re(&WS, r"\s+").replace_all(&s.to_lowercase(), " ").trim().to_string();
    let t = re(&FILL, r"^(hey |hi |ok |okay )?(clinqy[, ]+)?(please |pls |can you |could you |would you |kindly )*")
        .replace(&t, "")
        .to_string();
    re(&TAIL, r"[\s.!?,]*(please|pls)?[\s.!?]*$").replace(&t, "").to_string()
}

pub struct RouteMatch {
    pub workflow: Workflow,
    pub params: HashMap<String, String>,
}

/// A saved workflow that does exactly this request, its parameters read out of the words.
pub fn route(request: &str, all: &[Workflow]) -> Option<RouteMatch> {
    let want = normalize(request);
    if want.is_empty() {
        return None;
    }
    let mut best: Option<(RouteMatch, usize)> = None;
    for wf in all.iter().filter(|w| !w.steps.is_empty()) {
        let name = normalize(&wf.name);
        if name.is_empty() {
            continue;
        }
        let mut slots: Vec<(String, String)> = wf
            .defaults
            .clone()
            .unwrap_or_default()
            .into_iter()
            .filter(|(_, v)| v.len() >= 2 && !normalize(v).is_empty() && name.contains(&normalize(v)))
            .collect();
        slots.sort_by_key(|a| std::cmp::Reverse(a.1.len()));
        let mut pattern = regex::escape(&name);
        let mut order = vec![];
        for (key, value) in &slots {
            let lit = regex::escape(&normalize(value));
            if let Some(i) = pattern.find(&lit) {
                pattern.replace_range(i..i + lit.len(), "(.+?)");
                order.push(key.clone());
            }
        }
        let pattern = format!("^{}$", pattern.replace(' ', r"\s+"));
        let Ok(r) = Regex::new(&pattern) else { continue };
        let Some(m) = r.captures(&want) else { continue };
        let original = request.trim();
        let lower_original = original.to_lowercase();
        let mut params = HashMap::new();
        for (i, key) in order.iter().enumerate() {
            let Some(g) = m.get(i + 1) else { continue };
            let lowered = g.as_str();
            let cased =
                lower_original.find(lowered).map(|p| original[p..p + lowered.len()].to_string()).unwrap_or_else(|| lowered.to_string());
            params.insert(key.clone(), cased.trim().to_string());
        }
        let literal = name.len().saturating_sub(slots.iter().map(|s| s.1.len()).sum());
        if best.as_ref().map(|b| literal > b.1).unwrap_or(true) {
            best = Some((RouteMatch { workflow: wf.clone(), params }, literal));
        }
    }
    best.map(|b| b.0)
}

/// Requests that lean on what's on screen or selected ("reply to this") need the model to see it.
pub fn refers_to_context(request: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"\b(this|that|these|those|it|here|above|below|same|again|ye|yeh|isko|isse|usko|wahi)\b").is_match(&normalize(request))
}

/// Explicit corrections revise prior instructions rather than approving a cached method.
pub fn is_correction(request: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"^(actually|instead|no[ ,]|wrong|that(?:'s| is) (?:wrong|incorrect)|i meant|change (?:it|that)|correction)\b")
        .is_match(&normalize(request))
}

/// "continue", "also …", "now send it to Rahul": builds on the last task.
pub fn is_follow_up(request: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"^(continue|carry on|go on|keep going|resume|finish( it| that)?|complete( it| that)?|try again|retry|also|and|now|then|next|after that|same|aur|phir|ab|aage|jari rakho|continue karo)\b")
        .is_match(&normalize(request))
}

/// "no thanks", "that's all", "kuch nahi": nothing more to do.
pub fn is_dismissal(text: &str) -> bool {
    static CLEAN: OnceLock<Regex> = OnceLock::new();
    static R: OnceLock<Regex> = OnceLock::new();
    let t = re(&CLEAN, r"[^\p{L}\s']").replace_all(&text.to_lowercase(), "").split_whitespace().collect::<Vec<_>>().join(" ");
    re(&R, r"^(no|nope|nah|nothing|no thanks|no thank you|that's all|thats all|that's it|thats it|all good|done|i'm good|im good|thanks|thank you|ok thanks|okay thanks|great thanks|stop|cancel|never mind|nevermind|nahi|nahin|kuch nahi|bas|bas itna hi|bas itna|ruko|ho gaya|shukriya|dhanyavaad)( clinqy)?$").is_match(&t)
}

// MARK: - Runs that worked (replay cache)

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CachedRoute {
    #[serde(default = "new_id")]
    pub id: String,
    pub place: String,
    pub title: String,
    pub site: Option<String>,
    pub request: String,
    pub words: Vec<String>,
    pub steps: Vec<WorkflowStep>,
    pub uses: u32,
    pub misses: u32,
    pub last: String,
}

pub struct ReplayCache {
    all: Mutex<Vec<CachedRoute>>,
    offered: Mutex<Option<String>>,
}

pub fn replay_cache() -> &'static ReplayCache {
    static R: OnceLock<ReplayCache> = OnceLock::new();
    R.get_or_init(|| ReplayCache {
        all: Mutex::new(
            std::fs::read_to_string(store_path("replays.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default(),
        ),
        offered: Mutex::new(None),
    })
}

const STOP: &[&str] = &[
    "the", "and", "for", "this", "that", "these", "those", "also", "with", "from", "can", "you", "your", "now", "then", "again", "just",
    "all", "please", "into", "onto", "about", "some", "any", "its", "are", "was", "will",
];

pub fn content_words(request: &str) -> HashSet<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"[^\p{L}\p{N}\s]")
        .replace_all(&normalize(request), " ")
        .split_whitespace()
        .filter(|w| w.chars().count() > 2 && !STOP.contains(w))
        .map(String::from)
        .collect()
}

fn host(url: Option<&str>) -> Option<String> {
    let u = url::Url::parse(url?).ok()?;
    let h = u.host_str()?.to_lowercase();
    Some(h.strip_prefix("www.").map(String::from).unwrap_or(h))
}

fn place(url: Option<&str>, app: Option<&str>) -> String {
    host(url).unwrap_or_else(|| app.unwrap_or("").to_lowercase())
}

fn title_shape(title: Option<&str>) -> String {
    static D: OnceLock<Regex> = OnceLock::new();
    let Some(t) = title else { return String::new() };
    let t = re(&D, r"\d+").replace_all(&t.to_lowercase(), "#").split_whitespace().collect::<Vec<_>>().join(" ");
    t.chars().take(80).collect()
}

fn risky_step(s: &WorkflowStep) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    if s.submit == Some(true) || s.action == "shell" || s.action == "applescript" {
        return true;
    }
    if s.action == "key" && s.keys.as_deref().map(|k| k.contains("return") || k.contains("enter")).unwrap_or(false) {
        return true;
    }
    s.action == "click"
        && s.target.as_ref().map(|t| re(&R, r"(?i)\b(pay|buy|purchase|order|checkout|book|reserve|transfer|delete|remove|trash|send|submit|apply|post|publish|share|sign up|register|confirm)\b").is_match(&t.label)).unwrap_or(false)
}

impl ReplayCache {
    pub fn all(&self) -> Vec<CachedRoute> {
        self.all.lock().clone()
    }

    fn save(&self, all: &[CachedRoute]) {
        write_json("replays.json", &all);
    }

    pub fn record(
        &self,
        request: &str,
        trace: &[WorkflowStep],
        app: Option<&str>,
        url: Option<&str>,
        title: Option<&str>,
        redact: &[String],
    ) {
        let steps: Vec<WorkflowStep> = trace
            .iter()
            .map(|s| {
                let mut s = s.clone();
                for secret in redact.iter().filter(|s| s.len() >= 3) {
                    s.text = s.text.map(|t| t.replace(secret.as_str(), "••••"));
                }
                s
            })
            .collect();
        if steps.iter().filter(|s| !["expect", "wait", "open_url", "open_app"].contains(&s.action.as_str())).count() < 2 {
            return;
        }
        let words = content_words(request);
        if words.is_empty() {
            return;
        }
        let (pl, shape) = (place(url, app), title_shape(title));
        let site = steps.first().filter(|s| s.action == "open_url").and_then(|s| host(s.url.as_deref()));
        let mut all = self.all.lock();
        let mut sorted: Vec<String> = words.iter().cloned().collect();
        sorted.sort();
        if let Some(r) = all
            .iter_mut()
            .find(|r| r.place == pl && r.title == shape && r.site == site && r.words.iter().cloned().collect::<HashSet<_>>() == words)
        {
            r.steps = steps;
            r.request = request.into();
            r.uses += 1;
            r.misses = 0;
            r.last = now();
        } else {
            all.insert(
                0,
                CachedRoute {
                    id: new_id(),
                    place: pl,
                    title: shape,
                    site,
                    request: request.into(),
                    words: sorted,
                    steps,
                    uses: 1,
                    misses: 0,
                    last: now(),
                },
            );
        }
        all.sort_by(|a, b| b.last.cmp(&a.last));
        all.truncate(150);
        *self.offered.lock() = None;
        self.save(&all);
    }

    fn best(&self, request: &str, app: Option<&str>, url: Option<&str>, title: Option<&str>) -> Option<CachedRoute> {
        let want = content_words(request);
        if want.is_empty() {
            return None;
        }
        let (pl, shape) = (place(url, app), title_shape(title));
        let all = self.all.lock();
        all.iter()
            .filter_map(|r| {
                let have: HashSet<String> = r.words.iter().cloned().collect();
                let mut score = want.intersection(&have).count() as f64 / want.union(&have).count().max(1) as f64;
                if let Some(site) = &r.site {
                    if let Some(first) = site.split('.').next() {
                        if want.contains(first) {
                            score += 0.2;
                        }
                    }
                    if score < 0.5 {
                        return None;
                    }
                } else {
                    if r.place != pl {
                        return None;
                    }
                    if !shape.is_empty() && r.title == shape {
                        score += 0.3;
                    } else if want.len() < 3 {
                        return None;
                    }
                    if score < 0.5 {
                        return None;
                    }
                }
                Some((r.clone(), score - r.misses as f64 * 0.15))
            })
            .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
            .map(|x| x.0)
    }

    /// Text for the first message when a similar run worked before.
    pub fn hint(&self, request: &str, app: Option<&str>, url: Option<&str>, title: Option<&str>) -> Option<String> {
        let Some(r) = self.best(request, app, url, title) else {
            *self.offered.lock() = None;
            return None;
        };
        *self.offered.lock() = Some(r.id.clone());
        let steps: Vec<String> = r.steps.iter().enumerate().map(|(i, s)| format!("{}. {}", i + 1, s.summary())).collect();
        Some(format!(
            "\nYou did a very similar task before (“{}” on {}, worked {}×). These steps worked then:\n{}\nFollow them as the fastest known path, batching steps you can see, but check each against the screen: text typed last time is only an example unless this request uses it too, and still confirm before anything that sends, submits or pays. Where the screen differs, work it out as usual.",
            r.request.chars().take(80).collect::<String>(),
            r.site.clone().unwrap_or(r.place.clone()),
            r.uses,
            steps.join("\n")
        ))
    }

    pub fn corrected(&self, request: &str) {
        let mut all = self.all.lock();
        for route in all.iter_mut().filter(|r| normalize(&r.request) == normalize(request)) {
            route.misses += 1;
        }
        self.save(&all);
    }

    pub fn outcome(&self, ok: bool) {
        let offered = self.offered.lock().take();
        if ok {
            return;
        }
        let Some(id) = offered else { return };
        let mut all = self.all.lock();
        if let Some(i) = all.iter().position(|r| r.id == id) {
            all[i].misses += 1;
            if all[i].misses >= 2 && all[i].misses >= all[i].uses {
                all.remove(i);
            }
            self.save(&all);
        }
    }

    /// A replay safe to run with no model: the same request word for word, worked twice, never missed, nothing risky.
    pub fn replayable(&self, request: &str, app: Option<&str>, url: Option<&str>, title: Option<&str>) -> Option<Workflow> {
        let r = self.best(request, app, url, title)?;
        if r.uses < 2 || r.misses > 0 || normalize(&r.request) != normalize(request) || r.steps.iter().any(risky_step) {
            return None;
        }
        *self.offered.lock() = Some(r.id.clone());
        Some(Workflow::new(&r.request.chars().take(60).collect::<String>(), "Replayed from an earlier run", r.steps))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_with_slots() {
        let mut w = Workflow::new("message mom I'll be late", "", vec![WorkflowStep::new("open_app")]);
        w.defaults = Some(HashMap::from([("Message".to_string(), "I'll be late".to_string())]));
        let m = route("please message mom Stuck in traffic", &[w]).unwrap();
        assert_eq!(m.params["Message"], "Stuck in traffic");
    }

    #[test]
    fn follow_ups_and_dismissals() {
        assert!(is_follow_up("continue"));
        assert!(is_follow_up("now send it to Rahul"));
        assert!(!is_follow_up("open notepad"));
        assert!(is_dismissal("No thanks!"));
        assert!(!is_dismissal("no, open chrome"));
    }
}
