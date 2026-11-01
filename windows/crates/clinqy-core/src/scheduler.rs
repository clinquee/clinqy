//! Requests to run later, once or on repeat ("every weekday at 9 check my placement mail"), and reminders.
//! Stored as schedules.json / reminders.json; the app's timer runs whatever is due.

use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, NaiveTime, TimeZone, Timelike, Weekday};
use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Repeat {
    None,
    Daily,
    Weekdays,
    Hourly,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Item {
    #[serde(default = "new_id")]
    pub id: String,
    pub request: String,
    /// When it runs next (RFC 3339).
    pub next: String,
    pub rule: Repeat,
    #[serde(default, rename = "lastRun")]
    pub last_run: Option<String>,
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

fn path() -> std::path::PathBuf {
    crate::paths::data_dir().join("schedules.json")
}

pub fn all() -> Vec<Item> {
    let mut v: Vec<Item> = std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    v.sort_by(|a, b| a.next.cmp(&b.next));
    v
}

fn save(items: &[Item]) {
    if let Ok(t) = serde_json::to_string_pretty(items) {
        let _ = std::fs::write(path(), t);
    }
}

fn parse_time(s: &str) -> DateTime<Local> {
    DateTime::parse_from_rfc3339(s).map(|d| d.with_timezone(&Local)).unwrap_or_else(|_| Local::now())
}

fn is_weekend(d: &DateTime<Local>) -> bool {
    matches!(d.weekday(), Weekday::Sat | Weekday::Sun)
}

fn next_occurrence(now: DateTime<Local>, base: DateTime<Local>, rule: Repeat) -> DateTime<Local> {
    let mut d = base;
    match rule {
        Repeat::None => base,
        Repeat::Hourly => {
            while d <= now {
                d += Duration::hours(1);
            }
            d
        }
        Repeat::Daily | Repeat::Weekdays => {
            loop {
                d += Duration::days(1);
                if d > now && !(rule == Repeat::Weekdays && is_weekend(&d)) {
                    break;
                }
            }
            d
        }
    }
}

pub fn describe(item: &Item) -> String {
    let next = parse_time(&item.next);
    let today = Local::now().date_naive();
    let time = next.format("%H:%M");
    let day = if next.date_naive() == today {
        "today".to_string()
    } else if next.date_naive() == today.succ_opt().unwrap_or(today) {
        "tomorrow".to_string()
    } else {
        next.format("%a %-d %b").to_string()
    };
    match item.rule {
        Repeat::None => format!("{day} {time}"),
        Repeat::Hourly => format!("every hour, next {time}"),
        Repeat::Daily => format!("daily at {time}"),
        Repeat::Weekdays => format!("weekdays at {time}"),
    }
}

pub fn add_at(request: &str, when: DateTime<Local>, rule: Repeat) -> String {
    let text = request.trim();
    if text.is_empty() {
        return "FAILED: nothing to schedule".into();
    }
    let now = Local::now();
    let mut first = when;
    if first < now {
        first = if rule == Repeat::None { first + Duration::days(1) } else { next_occurrence(now, first, rule) };
    }
    if rule == Repeat::Weekdays && is_weekend(&first) {
        first = next_occurrence(first, first, Repeat::Weekdays);
    }
    let item = Item { id: new_id(), request: text.into(), next: first.to_rfc3339(), rule, last_run: None };
    let line = format!("scheduled: “{text}” — {}", describe(&item));
    let mut items = all();
    items.push(item);
    save(&items);
    crate::log::write(&line);
    line
}

/// Schedules from a phrase ("at 9am", "tomorrow 8:30", "in 20 minutes", "every weekday at 9"). None = unreadable.
pub fn add(request: &str, phrase: &str) -> Option<String> {
    let (when, rule) = parse(phrase, Local::now())?;
    Some(add_at(request, when, rule))
}

pub fn remove(id: &str) {
    save(&all().into_iter().filter(|i| i.id != id).collect::<Vec<_>>());
}

/// The first item due now, moved on to its next run (or removed). Runs missed by over two hours are skipped.
pub fn take_due() -> Option<Item> {
    let now = Local::now();
    let mut items = all();
    let mut fire: Option<Item> = None;
    let mut changed = false;
    let mut i = items.len();
    while i > 0 {
        i -= 1;
        let next = parse_time(&items[i].next);
        if next > now {
            continue;
        }
        let late = (now - next).num_seconds() > 2 * 3600;
        changed = true;
        if !late && fire.is_none() {
            fire = Some(items[i].clone());
        }
        if late {
            crate::log::write(&format!("schedule skipped (missed): “{}” at {}", items[i].request, items[i].next));
        }
        let fired = fire.as_ref().map(|f| f.id == items[i].id).unwrap_or(false);
        if items[i].rule == Repeat::None {
            if late || fired {
                items.remove(i);
            }
        } else if late || fired {
            if fired {
                items[i].last_run = Some(now.to_rfc3339());
            }
            items[i].next = next_occurrence(now, next, items[i].rule).to_rfc3339();
        }
    }
    if changed {
        save(&items);
    }
    fire
}

/// Reads "in 20 minutes", "at 9", "at 9:30 pm", "tomorrow at 8", "tonight", "every weekday at 9am", "daily 18:00",
/// "every hour", "monday at 10".
pub fn parse(phrase: &str, now: DateTime<Local>) -> Option<(DateTime<Local>, Repeat)> {
    let p = phrase.trim().to_lowercase();
    let has = |pat: &str| Regex::new(pat).map(|r| r.is_match(&p)).unwrap_or(false);
    if let Some(c) = Regex::new(r"\bin (\d+|an?|half an) ?(min|minute|minutes|mins|hour|hours|hr|hrs)\b").unwrap().captures(&p) {
        let n: i64 = c[1].parse().unwrap_or(if &c[1] == "half an" { 0 } else { 1 });
        let minutes = if c[2].starts_with('h') {
            if &c[1] == "half an" {
                30
            } else {
                n * 60
            }
        } else {
            n
        };
        return Some((now + Duration::minutes(minutes), Repeat::None));
    }
    let rule = if has(r"\bevery ?hour|\bhourly\b") {
        Repeat::Hourly
    } else if has(r"\b(every )?(weekday|weekdays|working day|workday)s?\b|\bmon(day)?\s*(-|to|–)\s*fri(day)?\b") {
        Repeat::Weekdays
    } else if has(r"\b(every ?day|daily|every (morning|evening|night|afternoon))\b") {
        Repeat::Daily
    } else {
        Repeat::None
    };
    if rule == Repeat::Hourly {
        let minute = Regex::new(r":(\d{2})").unwrap().captures(&p).and_then(|c| c[1].parse().ok()).unwrap_or(now.minute());
        let mut d = now.with_minute(minute)?.with_second(0)?;
        if d <= now {
            d += Duration::hours(1);
        }
        return Some((d, Repeat::Hourly));
    }
    let mut hour: Option<u32> = None;
    let mut minute = 0u32;
    if has(r"\bnoon\b") {
        hour = Some(12);
    } else if has(r"\bmidnight\b") {
        hour = Some(0);
    } else {
        let re = Regex::new(r"\b(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?").unwrap();
        let found = re.captures_iter(&p).find(|c| {
            // Not part of a date ("12/10") or a longer number.
            let end = c.get(0).unwrap().end();
            !p[end..].starts_with(|ch: char| ch.is_ascii_digit() || ch == '/')
        });
        if let Some(c) = found {
            let ampm = c.get(3).map(|m| m.as_str()).unwrap_or("");
            let mins = c.get(2).map(|m| m.as_str()).unwrap_or("");
            let explicit = has(r"\b(at|@|by|around)\s*\d") || !ampm.is_empty() || !mins.is_empty() || has(r"^\d") || rule != Repeat::None;
            if explicit {
                let mut h: u32 = c[1].parse().ok()?;
                minute = mins.parse().unwrap_or(0);
                if ampm.starts_with('p') && h < 12 {
                    h += 12;
                }
                if ampm.starts_with('a') && h == 12 {
                    h = 0;
                }
                // "at 7" said after 7 am: the 7 o'clock still ahead today (7 pm).
                let named_day = has(
                    r"\b(tomorrow|morning|sun|mon|tue|tues|wed|thu|thurs|fri|sat|sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b",
                );
                if ampm.is_empty() && (1..12).contains(&h) && !c[1].starts_with('0') && rule == Repeat::None && !named_day {
                    let today = at(now.date_naive(), h, minute)?;
                    let later = at(now.date_naive(), h + 12, minute)?;
                    if today <= now && later > now {
                        h += 12;
                    }
                }
                if h >= 24 || minute >= 60 {
                    return None;
                }
                hour = Some(h);
            }
        }
        if hour.is_none() {
            hour = if has(r"\bmorning\b") {
                Some(9)
            } else if has(r"\bafternoon\b") {
                Some(14)
            } else if has(r"\bevening\b") {
                Some(18)
            } else if has(r"\b(tonight|night)\b") {
                Some(21)
            } else {
                None
            };
        }
    }
    let mut day = now.date_naive();
    let mut explicit_day = false;
    if has(r"\btomorrow\b") {
        day = day.succ_opt()?;
        explicit_day = true;
    } else if rule == Repeat::None {
        if let Some(c) = Regex::new(r"\b(sun|mon|tue|wed|thu|fri|sat)(day|s|sday|nesday|rsday|urday)?\b").unwrap().captures(&p) {
            let names = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
            let want = names.iter().position(|n| *n == &c[1])? as i64;
            let cur = now.weekday().num_days_from_monday() as i64;
            let ahead = ((want - cur + 7) % 7).max(1);
            day += Duration::days(ahead);
            explicit_day = true;
        }
    }
    let mut d = at(day, hour?, minute)?;
    if d <= now {
        if explicit_day {
            return None;
        }
        d += Duration::days(1);
    }
    Some((d, rule))
}

fn at(day: NaiveDate, h: u32, m: u32) -> Option<DateTime<Local>> {
    Local.from_local_datetime(&day.and_time(NaiveTime::from_hms_opt(h, m, 0)?)).single()
}

// MARK: - Reminders (Clinqy shows them itself when they're due)

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Reminder {
    #[serde(default = "new_id")]
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub due: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub shown: bool,
}

fn reminders_path() -> std::path::PathBuf {
    crate::paths::data_dir().join("reminders.json")
}

pub fn reminders() -> Vec<Reminder> {
    std::fs::read_to_string(reminders_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

pub fn save_reminders(r: &[Reminder]) {
    if let Ok(t) = serde_json::to_string_pretty(r) {
        let _ = std::fs::write(reminders_path(), t);
    }
}

/// Reminders due now that haven't been shown (marked shown).
pub fn due_reminders() -> Vec<Reminder> {
    let now = Local::now();
    let mut all = reminders();
    let mut due = vec![];
    for r in all.iter_mut().filter(|r| !r.done && !r.shown) {
        if let Some(d) = r.due.as_deref().and_then(crate::when::parse_local) {
            if d <= now {
                r.shown = true;
                due.push(r.clone());
            }
        }
    }
    if !due.is_empty() {
        save_reminders(&all);
    }
    due
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<Local> {
        Local.with_ymd_and_hms(2026, 10, 12, 10, 0, 0).unwrap() // a Monday
    }

    #[test]
    fn phrases() {
        let (d, r) = parse("in 20 minutes", now()).unwrap();
        assert_eq!((d - now()).num_minutes(), 20);
        assert_eq!(r, Repeat::None);
        let (d, _) = parse("at 9am", now()).unwrap();
        assert_eq!((d.day(), d.hour()), (13, 9));
        let (d, _) = parse("at 7", now()).unwrap();
        assert_eq!(d.hour(), 19);
        let (d, r) = parse("every weekday at 9", now()).unwrap();
        assert_eq!((d.hour(), r), (9, Repeat::Weekdays));
        let (d, _) = parse("tomorrow 8:30", now()).unwrap();
        assert_eq!((d.day(), d.hour(), d.minute()), (13, 8, 30));
        let (d, _) = parse("friday at 10", now()).unwrap();
        assert_eq!(d.weekday(), Weekday::Fri);
        assert!(parse("whenever", now()).is_none());
    }
}
