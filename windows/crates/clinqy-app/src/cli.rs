//! The `clinqy` command: drive the Clinqy app from a terminal or any coding agent (Claude Code, Codex, Cursor,
//! Antigravity, OpenCode…). The same commands as on the Mac.

use crate::ipc;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub const HELP: &str = "clinqy — drive Clinqy from a terminal or any coding agent (Claude Code, Codex, Cursor, Antigravity…).

  clinqy run [--dry|--test|--background] [--agy|--claude] \"<task>\"
        Do a task like one asked in the app (saved to History; carries on by itself if it runs out of steps).
        --dry: point at each click/keystroke, don't do it. --test: a throwaway run (not saved, no carrying on).
        --background: work in a hidden browser, leaving your mouse, keyboard and windows alone.
  clinqy qa <test.md | folder | \"inline test\"> ... [--relearn] [--model sonnet|opus|haiku] [--agy] [--json]
        Run plain-English UI tests. The first run uses the model and compiles a script (saved in .clinqy\\ next to
        the test); later runs replay it with no model, healing only broken steps. Exit code 0 = all passed.
  clinqy workflow <name> [key=value ...]   Replay a saved workflow with parameters, no model.
  clinqy workflows                         List saved workflows.
  clinqy page [read|url]                   What's in the browser tab in front (via the extension), read-only.
  clinqy look [read|url]                   What's in front (the app's controls, or the browser tab), read-only.
  clinqy answer \"<text>\"                    Answer the question Clinqy is waiting on.
  clinqy status                            Whether a task is running, paused or in the background.
  clinqy tasks                             Recent tasks and what happened to them.
  clinqy add \"<text>\"                       More for the task: the running one, or the latest one if it's finished.
  clinqy stop                              Stop the current task now.
  clinqy pause | resume                    Hold the current task at its next step, then carry on.
  clinqy open                              Open the command bar.
  clinqy dashboard [live]                  Open the Clinqy window (settings, models, tasks), or the background work view.
  clinqy stats [days] [--last]             Success rate, time per turn, click outcomes, common failures (default 7 days).
  clinqy memory [\"request\"]                What memory holds (or exactly which facts a request would be sent).
  clinqy extension install [chrome|edge|brave]
        Clinqy adds its own browser extension (extensions page → Developer mode → Load unpacked), then checks it
        connected. Without a browser name it uses your default browser.
  clinqy extension reload                  Reload the browser extension from disk.
  clinqy model                             Which model Clinqy uses, and the choices.
  clinqy model <claude|codex|agy|ollama|anthropic|openai|gemini|openrouter|compatible> [model-id]
        Use that one (saved in the settings file), then check it really answers. `clinqy model test` checks again.
        `clinqy model auto` (the default): use what's installed, in this order: Claude Code, Codex, agy, Ollama.
  clinqy models [name]                     The models that provider offers on this PC (default: the one in use).
  clinqy connect <all|claude|agy|cursor|codex|gemini|windsurf|opencode> ...
        Add Clinqy as an MCP server to those coding agents (keeps their other servers). all: every one on this PC.
  clinqy setup [--model <name>] [--connect <names|all|none>] [--no-extension]
        Everything at once: the model (auto unless named), coding agents (all unless named), the browser extension,
        then what's ready and what still needs you.
  clinqy voice check [seconds]             Try Windows' speech service on this PC, and say what it heard.
  clinqy update [--check] [--force]        Install the newest version, keeping your settings and data. --check only
        looks; --force reinstalls even when up to date. It waits for you if a task is running.
  clinqy settings [--path]                 Open the settings file (keys, hotkeys, everything else).
  clinqy doctor                            What's set up and what isn't (model, extension, voice, Outlook).
  clinqy mcp                               Serve Clinqy as an MCP server on stdio (claude mcp add clinqy -- clinqy mcp).
";

pub fn rt() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("runtime")
}

fn fail(msg: &str) -> i32 {
    eprintln!("{msg}");
    2
}

fn print_step(v: &Value) {
    match v["event"].as_str() {
        Some("step") => {
            let mark = match v["state"].as_str() {
                Some("failed") => "✗",
                Some("info") => "·",
                _ => "→",
            };
            println!("{mark} {}", v["text"].as_str().unwrap_or(""));
        }
        Some("log") => println!("  {}", v["text"].as_str().unwrap_or("")),
        _ => {}
    }
}

pub fn main(args: Vec<String>) -> i32 {
    let cmd = args.first().map(|s| s.trim_start_matches('-').to_string()).unwrap_or_else(|| "help".into());
    let rest: Vec<String> = args.iter().skip(1).cloned().collect();
    match cmd.as_str() {
        "run" => run(&rest),
        "qa" => qa(&rest),
        "workflow" => {
            let Some(name) = rest.first() else { return fail("usage: clinqy workflow <name> [key=value ...]") };
            let params: serde_json::Map<String, Value> = rest[1..].iter().filter_map(|kv| kv.split_once('=')).map(|(k, v)| (k.to_string(), json!(v))).collect();
            stream("workflow", json!({"name": name, "params": params}), true)
        }
        "workflows" => {
            for w in clinqy_core::workflow::workflows().all() {
                println!(
                    "{}{} — {} steps, run {}×{}",
                    w.name,
                    if w.params.is_empty() { String::new() } else { format!(" ({})", w.params.join(", ")) },
                    w.steps.len(),
                    w.runs,
                    w.schedule.map(|s| format!(" · daily {s}")).unwrap_or_default()
                );
            }
            0
        }
        "page" => {
            let sub = rest.first().cloned().unwrap_or_else(|| "page".into());
            simple("page", json!({"cmd": sub}), true)
        }
        "status" => {
            let v = rt().block_on(async { ipc::call("status", json!({}), |_| {}).await.ok() });
            let s = v.as_ref().map(|v| &v["snapshot"]);
            match s {
                Some(s) if s["running"] == true => println!("running{}{}", if s["paused"] == true { ", paused" } else { "" }, if s["background"] == true { ", in the background" } else { "" }),
                _ => println!("idle"),
            }
            0
        }
        "add" => simple("add", json!({"text": rest.join(" ")}), true),
        "answer" => simple("answer", json!({"text": rest.join(" ")}), false),
        "stop" | "cancel" => simple("cancel", json!({}), false),
        "tasks" => {
            for t in clinqy_core::taskstore::peek().iter().rev().take(20) {
                println!("{} {:<16} {}{}", t.short_id(), t.state.label(), if t.background { "[background] " } else { "" }, t.request.chars().take(80).collect::<String>());
                if let Some(p) = &t.pending_action {
                    println!("         check outcome: {p}. It will not be replayed automatically.");
                }
            }
            0
        }
        "pause" => simple("pause", json!({}), false),
        "resume" => simple("resume", json!({}), false),
        "open" | "show" => simple("show", json!({}), true),
        "dashboard" | "app" => simple("dashboard", json!({"page": rest.first()}), true),
        "extension" => {
            if rest.first().map(|s| s == "reload").unwrap_or(false) {
                simple("reload-extension", json!({}), true)
            } else if rest.first().map(|s| s == "install").unwrap_or(false) {
                extension_install(rest.get(1).map(String::as_str))
            } else {
                if let Some(d) = crate::setup::extension_dir() {
                    println!("{}", d.display());
                }
                0
            }
        }
        "stats" => {
            let days = rest.iter().find_map(|r| r.parse::<f64>().ok()).unwrap_or(7.0);
            println!("{}", clinqy_core::stats::report(days, rest.iter().any(|r| r == "--last")));
            0
        }
        "memory" => {
            let q = rest.iter().filter(|r| !r.starts_with("--")).cloned().collect::<Vec<_>>().join(" ");
            let facts = clinqy_core::memory::entries();
            println!("{} facts in {}", facts.len(), clinqy_core::memory::path().display());
            if q.is_empty() {
                for f in facts {
                    println!("{}{}", if clinqy_core::memory::is_profile(&f.text) { "P " } else { "  " }, f.line());
                }
            } else {
                let (sent, omitted) = clinqy_core::memory::relevant(&q, None, None, 40);
                println!("A request “{q}” is sent {} facts ({omitted} left out):", sent.len());
                for f in sent {
                    println!("{}{f}", if clinqy_core::memory::is_profile(&f) { "P " } else { "  " });
                }
            }
            0
        }
        "model" => model_cmd(&rest),
        "models" => models_cmd(&rest),
        "connect" => connect_cmd(&rest),
        "settings" | "config" => {
            crate::setup::ensure_env_file();
            let p = clinqy_core::paths::env_file();
            println!("{}", p.display());
            if !rest.iter().any(|a| a == "--path") {
                use std::os::windows::process::CommandExt;
                let _ = std::process::Command::new("notepad.exe").arg(&p).creation_flags(clinqy_core::session::CREATE_NO_WINDOW).spawn();
            }
            0
        }
        "setup" => setup_cmd(&rest),
        "doctor" | "check" => {
            // The extension connects to the app, not to this process: ask the app (when it's running).
            let ext = rt().block_on(async { ipc::call("status", json!({}), |_| {}).await.ok().and_then(|v| v["extension"].as_bool()) });
            let card = crate::setup::check_card(Some(ext.unwrap_or(false)));
            if ext.is_none() {
                println!("(Clinqy isn't running — start it to connect the browser extension.)");
            }
            println!("{}", card.plain());
            0
        }
        "mcp" => crate::mcp::serve(),
        "look" => {
            let v = rt().block_on(crate::mcp::look(rest.first().map(String::as_str).unwrap_or("page")));
            println!("{}", v["content"][0]["text"].as_str().unwrap_or(""));
            0
        }
        "url" => {
            // clinqy:// links (registered by the installer) land here.
            let Some(u) = rest.first() else { return 2 };
            simple("url", json!({"url": u}), true)
        }
        "transcribe" => {
            let Some(f) = rest.first() else { return fail("usage: clinqy transcribe <audio.wav>") };
            let rt = rt();
            let _g = rt.enter();
            let voice = crate::voice::Voice::new(Box::new(|_| {}), Box::new(|t, _| eprintln!("{t}")));
            let t0 = std::time::Instant::now();
            match rt.block_on(voice.transcribe_file(Path::new(f))) {
                Ok(t) => {
                    println!("{} ms: {t}", t0.elapsed().as_millis());
                    0
                }
                Err(e) => fail(&e.to_string()),
            }
        }
        "voice" => {
            let secs = rest.get(1).and_then(|s| s.parse::<u64>().ok()).unwrap_or(3);
            let end = std::time::Instant::now() + std::time::Duration::from_secs(secs);
            match crate::winspeech::listen(&|| std::time::Instant::now() >= end) {
                Ok(text) => {
                    println!("Windows speech works. Heard: {text:?}");
                    0
                }
                Err(e) => fail(&format!("Windows speech can't run: {e}")),
            }
        }
        "update" | "upgrade" => crate::update::command(&rest),
        "version" => {
            println!("clinqy {}", env!("CARGO_PKG_VERSION"));
            0
        }
        _ => {
            print!("{HELP}");
            if cmd == "help" || cmd == "h" {
                0
            } else {
                2
            }
        }
    }
}

/// One request, printing its text answer.
fn simple(cmd: &str, args: Value, start_app: bool) -> i32 {
    rt().block_on(async {
        if start_app {
            if let Err(e) = ipc::ensure_app().await {
                return fail(&e.to_string());
            }
        }
        match ipc::call(cmd, args, |_| {}).await {
            Ok(v) if v["event"] == "error" => fail(&format!("ERROR: {}", v["error"].as_str().unwrap_or("?"))),
            Ok(v) => {
                if let Some(t) = v["text"].as_str() {
                    println!("{t}");
                }
                0
            }
            Err(e) => fail(&e.to_string()),
        }
    })
}

/// A request that streams steps; exits 0 when it ended well.
fn stream(cmd: &str, args: Value, start_app: bool) -> i32 {
    rt().block_on(async {
        if start_app {
            if let Err(e) = ipc::ensure_app().await {
                return fail(&e.to_string());
            }
        }
        let mut last_q = String::new();
        let r = ipc::call(cmd, args, |v| {
            if v["event"] == "question" {
                let q = v["text"].as_str().unwrap_or("").to_string();
                if q != last_q {
                    println!("? {q}  (answer in the app, or: clinqy answer \"…\")");
                    last_q = q;
                }
            } else {
                print_step(v);
            }
        })
        .await;
        match r {
            Ok(v) if v["event"] == "error" => fail(&format!("ERROR: {}", v["error"].as_str().unwrap_or("?"))),
            Ok(v) => {
                let ok = v["ok"] == true;
                println!("{} {}", if ok { "✓" } else { "✗" }, v["answer"].as_str().unwrap_or(""));
                if ok {
                    0
                } else {
                    1
                }
            }
            Err(e) => fail(&e.to_string()),
        }
    })
}

fn run(rest: &[String]) -> i32 {
    let mut a = json!({});
    let mut words = vec![];
    for r in rest {
        match r.as_str() {
            "--dry" => a["dry"] = json!(true),
            "--background" | "--bg" => a["background"] = json!(true),
            "--test" => a["test"] = json!(true),
            "--agy" | "--agy-cli" => a["agy"] = json!(true),
            "--claude" | "--claude-cli" => a["claude"] = json!(true),
            "--help" | "-h" => {
                println!("usage: clinqy run [--dry] [--test] [--claude|--agy] <request…>");
                return 0;
            }
            other => words.push(other.to_string()),
        }
    }
    if words.is_empty() {
        return fail("usage: clinqy run [--dry|--test] \"<task>\"");
    }
    a["task"] = json!(words.join(" "));
    stream("run", a, true)
}

fn tests_in(target: &str) -> Vec<String> {
    let p = Path::new(target);
    if p.is_dir() {
        let mut out = vec![];
        let mut stack = vec![p.to_path_buf()];
        while let Some(d) = stack.pop() {
            let Ok(rd) = std::fs::read_dir(&d) else { continue };
            for e in rd.flatten() {
                let path = e.path();
                if path.is_dir() {
                    if e.file_name() != ".clinqy" {
                        stack.push(path);
                    }
                } else if path.extension().map(|x| x == "md" || x == "txt").unwrap_or(false) {
                    out.push(std::fs::canonicalize(&path).unwrap_or(path).display().to_string().trim_start_matches(r"\\?\").to_string());
                }
            }
        }
        out.sort();
        out
    } else if p.is_file() {
        vec![std::fs::canonicalize(p).map(|c| c.display().to_string().trim_start_matches(r"\\?\").to_string()).unwrap_or_else(|_| target.to_string())]
    } else {
        vec![format!("inline:{target}")]
    }
}

fn qa(rest: &[String]) -> i32 {
    let (mut relearn, mut json_out, mut agy) = (false, false, false);
    let mut model: Option<String> = None;
    let mut targets = vec![];
    let mut it = rest.iter();
    while let Some(r) = it.next() {
        match r.as_str() {
            "--relearn" => relearn = true,
            "--json" => json_out = true,
            "--agy" | "--agy-cli" => agy = true,
            "--claude" | "--claude-cli" => agy = false,
            "--model" => model = it.next().cloned(),
            other => targets.push(other.to_string()),
        }
    }
    if targets.is_empty() {
        return fail("usage: clinqy qa <test.md|folder|\"inline test\"> [--relearn] [--model m] [--agy] [--json]");
    }
    let files: Vec<String> = targets.iter().flat_map(|t| tests_in(t)).collect();
    let rt = rt();
    if let Err(e) = rt.block_on(ipc::ensure_app()) {
        return fail(&e.to_string());
    }
    let mut failed = false;
    for f in files {
        let out = std::env::temp_dir().join(format!("clinqy-qa-{}.json", uuid::Uuid::new_v4()));
        let mut a = json!({"relearn": relearn, "agy": agy, "out": out.display().to_string()});
        if let Some(t) = f.strip_prefix("inline:") {
            a["text"] = json!(t);
        } else {
            a["path"] = json!(f);
        }
        if let Some(m) = &model {
            a["model"] = json!(m);
        }
        let r = rt.block_on(ipc::call("qa", a, |_| {}));
        if let Err(e) = r {
            println!("ERROR  {}: {e}", f.trim_start_matches("inline:"));
            failed = true;
            continue;
        }
        let report: Option<Value> = std::fs::read_to_string(&out).ok().and_then(|t| serde_json::from_str(&t).ok());
        let _ = std::fs::remove_file(&out);
        let Some(r) = report else {
            println!("TIMEOUT  {}", f.trim_start_matches("inline:"));
            failed = true;
            continue;
        };
        let passed = r["passed"] == true;
        failed |= !passed;
        if json_out {
            println!("{r}");
            continue;
        }
        println!("{}  {}  ({}, {:.1}s)", if passed { "PASS" } else { "FAIL" }, r["name"].as_str().unwrap_or(""), r["mode"].as_str().unwrap_or(""), r["durationMs"].as_f64().unwrap_or(0.0) / 1000.0);
        for c in r["checks"].as_array().cloned().unwrap_or_default() {
            let pass = c["pass"] == true;
            let note = c["note"].as_str().unwrap_or("");
            println!("   {} {}{}", if pass { "✓" } else { "✗" }, c["text"].as_str().unwrap_or(""), if !pass && !note.is_empty() { format!("  — {note}") } else { String::new() });
        }
        if !passed {
            let steps = r["steps"].as_array().cloned().unwrap_or_default();
            for s in steps.iter().rev().take(6).rev() {
                println!("   · {}", s.as_str().unwrap_or(""));
            }
            if let Some(m) = r["message"].as_str().filter(|m| !m.is_empty()) {
                println!("   {m}");
            }
        }
    }
    if failed {
        1
    } else {
        0
    }
}

pub fn _unused(_: PathBuf) {}

/// `clinqy model [name [model-id] | test]`.
fn model_cmd(rest: &[String]) -> i32 {
    use crate::onboard;
    let current = clinqy_core::provider::Provider::current();
    let Some(first) = rest.first().map(|s| s.to_lowercase()) else {
        println!(
            "Clinqy uses: {} ({}), model {}{}",
            onboard::short_name(current),
            current.label(),
            onboard::model_label(current),
            if onboard::is_auto() { " — picked automatically (clinqy model <name> to choose)" } else { "" }
        );
        println!("\nChoices (clinqy model <name> [model-id], or clinqy model auto):");
        for (name, p, what) in onboard::MODELS {
            let state = match onboard::readiness(p) {
                Ok(_) if p.is_cli() => "installed",
                Ok(_) => "ready",
                Err(_) if p.is_cli() => "not installed",
                Err(_) => "needs setup",
            };
            println!("  {}{name:<11} {what:<36} {state}", if p == current { "* " } else { "  " });
        }
        return 0;
    };
    let p = if first == "test" {
        current
    } else if first == "auto" {
        match onboard::choose_auto() {
            Ok(p) => {
                println!("Clinqy picks what you have (Claude Code, then Codex, then agy, then Ollama, then an API key): {}.", onboard::short_name(p));
                p
            }
            Err(e) => return fail(&format!("couldn't save the settings file: {e}")),
        }
    } else {
        let Some(p) = onboard::MODELS.iter().find(|m| m.0 == first).map(|m| m.1).or_else(|| clinqy_core::provider::Provider::parse(&first)) else {
            return fail(&format!("I don't know the model {first:?}. Choices: {}", onboard::MODELS.iter().map(|m| m.0).collect::<Vec<_>>().join(", ")));
        };
        if let Err(e) = onboard::choose(p, rest.get(1).map(String::as_str)) {
            return fail(&format!("couldn't save the settings file: {e}"));
        }
        println!("Clinqy now uses {} (saved in {}).", onboard::short_name(p), clinqy_core::paths::env_file().display());
        p
    };
    if let Err(fix) = onboard::readiness(p) {
        println!("✗ Not ready: {fix}");
        println!("  Then run: clinqy model test");
        return 1;
    }
    println!("Checking that {} answers (model {})…", onboard::short_name(p), onboard::model_label(p));
    match rt().block_on(onboard::test(p)) {
        Ok(t) => {
            println!("✓ It works ({:.1} s). Press Ctrl+Alt and ask Clinqy something.", t.as_secs_f64());
            0
        }
        Err(e) => {
            println!("✗ It didn't answer: {e}");
            if p.is_cli() {
                println!("  If you haven't yet, run `{}` once in a new terminal and log in, then: clinqy model test", onboard::short_name(p));
            }
            1
        }
    }
}

/// `clinqy models [name]`.
fn models_cmd(rest: &[String]) -> i32 {
    use crate::onboard;
    let p = match rest.first() {
        Some(name) => {
            let name = name.to_lowercase();
            match onboard::MODELS.iter().find(|m| m.0 == name).map(|m| m.1).or_else(|| clinqy_core::provider::Provider::parse(&name)) {
                Some(p) => p,
                None => return fail(&format!("I don't know the model provider {name:?}")),
            }
        }
        None => clinqy_core::provider::Provider::current(),
    };
    let saved = clinqy_core::models::saved(p);
    println!("{} on this PC (clinqy model {} <id> to choose):", onboard::short_name(p), onboard::short_name(p));
    for m in rt().block_on(clinqy_core::models::list(p)) {
        println!("  {}{:<28} {}", if m.id == saved { "* " } else { "  " }, if m.id.is_empty() { "(default)" } else { m.id.as_str() }, m.label);
    }
    0
}

/// `clinqy connect <agent> ...`.
fn connect_cmd(rest: &[String]) -> i32 {
    use crate::onboard;
    if rest.is_empty() {
        return fail(&format!("usage: clinqy connect <all|{}> ...", onboard::AGENTS.join("|")));
    }
    let mut code = 0;
    let mut names: Vec<String> = rest.iter().flat_map(|a| a.split(',')).map(|a| a.trim().to_lowercase()).filter(|a| !a.is_empty()).collect();
    if names.iter().any(|n| n == "all") {
        names = onboard::installed_agents().iter().map(|a| a.to_string()).collect();
        if names.is_empty() {
            println!("No coding agents found on this PC.");
        }
    }
    for agent in names {
        match onboard::connect(&agent) {
            Ok(done) => println!("✓ {done}"),
            Err(e) => {
                println!("✗ {agent}: {e}");
                code = 1;
            }
        }
    }
    if code == 0 {
        println!("Restart those agents to see Clinqy's tools (clinqy_run, clinqy_look, clinqy_stats).");
    }
    code
}

/// `clinqy extension install [browser]`: Clinqy loads its own extension, like a person would, then waits for it to
/// connect.
fn extension_install(browser: Option<&str>) -> i32 {
    let (name, task, dir) = match crate::onboard::extension_task(browser) {
        Ok(t) => t,
        Err(e) => return fail(&e),
    };
    let page = name.split(' ').next_back().unwrap_or("").to_lowercase();
    let page = format!("{page}://extensions");
    let connected = || rt().block_on(async { ipc::call("status", json!({}), |_| {}).await.ok().and_then(|v| v["extension"].as_bool()).unwrap_or(false) });
    let code = rt().block_on(async { ipc::ensure_app().await.map(|_| 0).unwrap_or(2) });
    if code != 0 {
        return fail("couldn't start Clinqy");
    }
    if connected() {
        println!("✓ The browser extension is already connected.");
        return 0;
    }
    println!("Clinqy is adding its extension to {name} (folder {})…", dir.display());
    let r = stream("run", json!({"text": task}), true);
    for _ in 0..20 {
        if connected() {
            println!("✓ The browser extension is connected.");
            return 0;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    println!("✗ The extension didn't connect{}. Do it by hand: open {page}, turn on Developer mode, click Load unpacked and pick {}", if r == 0 { " yet" } else { "" }, dir.display());
    1
}

/// `clinqy setup`: gets a new install working in one go, and ends by saying exactly what still needs the person.
fn setup_cmd(rest: &[String]) -> i32 {
    use crate::onboard;
    use clinqy_core::provider::Provider;
    let value = |flag: &str| rest.iter().position(|a| a == flag).and_then(|i| rest.get(i + 1)).map(|v| v.to_lowercase());
    let model = value("--model").unwrap_or_else(|| "auto".into());
    let connect = value("--connect").unwrap_or_else(|| "all".into());
    let mut needs: Vec<String> = vec![];
    crate::setup::ensure_env_file();
    if let Err(e) = rt().block_on(ipc::ensure_app()) {
        return fail(&format!("Clinqy wouldn't start: {e}"));
    }

    println!("Model");
    let p = if model == "auto" {
        onboard::choose_auto().unwrap_or_else(|_| Provider::current())
    } else {
        match onboard::MODELS.iter().find(|m| m.0 == model).map(|m| m.1).or_else(|| Provider::parse(&model)) {
            Some(p) => {
                let _ = onboard::choose(p, None);
                p
            }
            None => return fail(&format!("I don't know the model {model:?}. Choices: auto, {}", onboard::MODELS.iter().map(|m| m.0).collect::<Vec<_>>().join(", "))),
        }
    };
    match onboard::readiness(p) {
        Err(fix) => {
            println!("  ✗ {}: not ready", onboard::short_name(p));
            needs.push(fix);
        }
        Ok(_) => match rt().block_on(onboard::test(p)) {
            Ok(t) => println!("  ✓ {} works, model {} ({:.1} s)", onboard::short_name(p), onboard::model_label(p), t.as_secs_f64()),
            Err(e) => {
                println!("  ✗ {} didn't answer: {e}", onboard::short_name(p));
                needs.push(format!("Run `{}` once in a new terminal and log in, then run: clinqy model test", onboard::short_name(p)));
            }
        },
    }

    if connect != "none" {
        println!("Coding agents");
        let names: Vec<String> = if connect == "all" { onboard::installed_agents().iter().map(|a| a.to_string()).collect() } else { connect.split(',').map(|a| a.trim().to_string()).collect() };
        if names.is_empty() {
            println!("  none found");
        }
        for agent in names {
            match onboard::connect(&agent) {
                Ok(done) => println!("  ✓ {done}"),
                Err(e) => {
                    println!("  ✗ {agent}: {e}");
                    needs.push(format!("Connect {agent} to Clinqy: {e}"));
                }
            }
        }
    }

    let connected = || rt().block_on(async { ipc::call("status", json!({}), |_| {}).await.ok().and_then(|v| v["extension"].as_bool()).unwrap_or(false) });
    println!("Browser extension");
    if connected() {
        println!("  ✓ connected");
    } else if rest.iter().any(|a| a == "--no-extension") {
        needs.push("Add the browser extension: run clinqy extension install".to_string());
    } else if extension_install(None) != 0 {
        needs.push("Add the browser extension by hand: tray icon → Browser extension…, turn on Developer mode, click Load unpacked and pick the folder it shows.".to_string());
    }

    println!();
    if needs.is_empty() {
        println!("Everything is ready. Tap Ctrl+Alt to type a request, hold Ctrl+H to say it. Open settings with the gear on the bar, or: clinqy dashboard");
        0
    } else {
        println!("Needs you:");
        for n in &needs {
            println!("  - {n}");
        }
        1
    }
}
