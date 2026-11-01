//! `clinqy stats`: how runs are going, from runs.jsonl and agent.log — success rate (overall and per app), the
//! slowest runs, model time vs action time per turn, how clicks went, and the most common failure reasons.

use std::collections::HashMap;

fn runs(days: f64) -> Vec<serde_json::Value> {
    let since = chrono::Utc::now() - chrono::Duration::seconds((days * 86400.0) as i64);
    std::fs::read_to_string(crate::paths::log_dir().join("runs.jsonl"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .filter(|r| r["date"].as_str().and_then(|d| chrono::DateTime::parse_from_rfc3339(d).ok()).map(|d| d >= since).unwrap_or(false))
        .collect()
}

fn log_lines() -> Vec<String> {
    let mut text = std::fs::read_to_string(crate::paths::agent_log().with_extension("log.1")).unwrap_or_default();
    text += &std::fs::read_to_string(crate::paths::agent_log()).unwrap_or_default();
    text.lines().map(String::from).collect()
}

fn pct(a: usize, b: usize) -> String {
    if b == 0 {
        "-".into()
    } else {
        format!("{:.0}%", a as f64 * 100.0 / b as f64)
    }
}

pub fn report(days: f64, last: bool) -> String {
    let lines = log_lines();
    if last {
        let start = lines.iter().rposition(|l| l.starts_with("=== ")).unwrap_or(0);
        let run = &lines[start..];
        let mut out = vec![format!("Last run: {}", run.first().map(|l| l.trim_start_matches("=== ")).unwrap_or("(none)"))];
        for l in run.iter().skip(1) {
            let body = l.split_once("] ").map(|x| x.1).unwrap_or(l);
            if body.starts_with("turn ")
                || body.starts_with("  → ")
                || body.starts_with("    ✗")
                || body.starts_with('✓')
                || body.starts_with('✗')
                || body.contains("observe:")
            {
                out.push(format!("  {}", body.chars().take(160).collect::<String>()));
            }
        }
        return out.join("\n");
    }
    let rs = runs(days);
    let mut out = vec![];
    let ok = rs.iter().filter(|r| r["ok"] == true).count();
    let stopped = rs.iter().filter(|r| r["stopped"] == true).count();
    out.push(format!(
        "Runs in the last {days} days: {} · {} succeeded ({}) · {stopped} stopped by you",
        rs.len(),
        ok,
        pct(ok, rs.len().saturating_sub(stopped))
    ));
    if !rs.is_empty() {
        let secs: Vec<f64> = rs.iter().filter_map(|r| r["seconds"].as_f64()).collect();
        let mean = secs.iter().sum::<f64>() / secs.len().max(1) as f64;
        let turns: f64 = rs.iter().filter_map(|r| r["turns"].as_f64()).sum::<f64>() / rs.len() as f64;
        out.push(format!("Average: {mean:.1} s per run, {turns:.1} model turns"));
        let mut by_app: HashMap<String, (usize, usize)> = HashMap::new();
        for r in &rs {
            let e = by_app.entry(r["app"].as_str().filter(|a| !a.is_empty()).unwrap_or("(none)").to_string()).or_default();
            e.1 += 1;
            if r["ok"] == true {
                e.0 += 1;
            }
        }
        let mut apps: Vec<_> = by_app.into_iter().collect();
        apps.sort_by_key(|a| std::cmp::Reverse(a.1 .1));
        out.push("By app: ".to_string() + &apps.iter().take(8).map(|(a, (o, n))| format!("{a} {o}/{n}")).collect::<Vec<_>>().join(" · "));
        let mut slow: Vec<&serde_json::Value> = rs.iter().collect();
        slow.sort_by(|a, b| b["seconds"].as_f64().partial_cmp(&a["seconds"].as_f64()).unwrap_or(std::cmp::Ordering::Equal));
        out.push("Slowest:".into());
        for r in slow.iter().take(3) {
            out.push(format!("  {:.0} s  {}", r["seconds"].as_f64().unwrap_or(0.0), r["request"].as_str().unwrap_or("")));
        }
    }
    // Model time per turn, from agent.log ("turn N · 1234 ms · …").
    let turn_ms: Vec<f64> = lines
        .iter()
        .filter_map(|l| {
            let i = l.find("] turn ")?;
            let rest = &l[i..];
            let ms = rest.split(" · ").nth(1)?.trim_end_matches(" ms").parse::<f64>().ok()?;
            Some(ms)
        })
        .collect();
    if !turn_ms.is_empty() {
        let mut s = turn_ms.clone();
        s.sort_by(|a, b| a.partial_cmp(b).unwrap());
        out.push(format!(
            "Model reply: median {:.1} s, slowest 10% over {:.1} s ({} turns)",
            s[s.len() / 2] / 1000.0,
            s[s.len() * 9 / 10] / 1000.0,
            s.len()
        ));
    }
    // Clicks.
    let clicks: Vec<Vec<&str>> = lines
        .iter()
        .filter_map(|l| l.split("click: ").nth(1))
        .map(|c| c.split_whitespace().collect::<Vec<_>>())
        .filter(|p| p.len() >= 5)
        .collect();
    if !clicks.is_empty() {
        let first = clicks.iter().filter(|c| c[3] == "ok" && c[4] == "1").count();
        let rescued: HashMap<&str, usize> = clicks.iter().filter(|c| c[3] == "ok" && c[4] != "1").fold(HashMap::new(), |mut m, c| {
            *m.entry(c[2]).or_default() += 1;
            m
        });
        let mut hard: HashMap<&str, usize> = HashMap::new();
        for c in clicks.iter().filter(|c| c[3] != "ok") {
            *hard.entry(c[1]).or_default() += 1;
        }
        let mut hard: Vec<_> = hard.into_iter().collect();
        hard.sort_by_key(|a| std::cmp::Reverse(a.1));
        out.push(format!(
            "Clicks: {} · first try worked {} · rescued by {} · hardest: {}",
            clicks.len(),
            pct(first, clicks.len()),
            if rescued.is_empty() { "-".into() } else { rescued.iter().map(|(k, v)| format!("{k} {v}")).collect::<Vec<_>>().join(", ") },
            if hard.is_empty() {
                "-".into()
            } else {
                hard.iter().take(4).map(|(k, v)| format!("{k} ({v})")).collect::<Vec<_>>().join(", ")
            }
        ));
    }
    // Failure reasons.
    let mut reasons: HashMap<String, usize> = HashMap::new();
    for l in &lines {
        if let Some(i) = l.find("✗ FAILED: ") {
            let why: String = l[i + 11..].split(';').next().unwrap_or("").chars().take(70).collect();
            *reasons.entry(why).or_default() += 1;
        }
    }
    if !reasons.is_empty() {
        let mut r: Vec<_> = reasons.into_iter().collect();
        r.sort_by_key(|a| std::cmp::Reverse(a.1));
        out.push("Most common failed steps:".into());
        for (why, n) in r.iter().take(5) {
            out.push(format!("  {n}× {why}"));
        }
    }
    out.join("\n")
}
