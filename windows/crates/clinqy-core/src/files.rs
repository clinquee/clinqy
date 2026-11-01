//! Files without clicking through File Explorer: reading text out of documents (PDF, Word, text, HTML), listing,
//! renaming and moving in batches that can be undone, sorting a folder into subfolders, and tables in and out
//! (CSV, TSV). Searching the index is the platform's job (Windows Search).

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub fn bytes(n: u64) -> String {
    match n {
        0..=999 => format!("{n} bytes"),
        1_000..=999_999 => format!("{:.0} KB", n as f64 / 1e3),
        1_000_000..=999_999_999 => format!("{:.1} MB", n as f64 / 1e6),
        _ => format!("{:.2} GB", n as f64 / 1e9),
    }
}

pub fn mime(p: &Path) -> &'static str {
    match p.extension().map(|e| e.to_string_lossy().to_lowercase()).as_deref() {
        Some("pdf") => "application/pdf",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("txt") => "text/plain",
        Some("csv") => "text/csv",
        Some("json") => "application/json",
        Some("doc") => "application/msword",
        Some("docx") => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        Some("xlsx") => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        Some("pptx") => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        Some("zip") => "application/zip",
        Some("mp4") => "video/mp4",
        Some("mp3") => "audio/mpeg",
        _ => "application/octet-stream",
    }
}

/// The text of a document on disk (capped at 12k characters), or None.
pub async fn read_text(path: &Path) -> Option<String> {
    let p = path.to_path_buf();
    tokio::task::spawn_blocking(move || read_text_sync(&p)).await.ok().flatten()
}

pub fn read_text_sync(path: &Path) -> Option<String> {
    let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    let text = match ext.as_str() {
        "pdf" => pdf_text(path)?,
        "docx" | "pptx" | "xlsx" | "odt" => office_text(path, &ext)?,
        "html" | "htm" => strip_tags(&std::fs::read_to_string(path).ok()?),
        _ => {
            let bytes = std::fs::read(path).ok()?;
            if bytes.iter().take(4096).filter(|b| **b == 0).count() > 8 {
                return None; // binary
            }
            String::from_utf8_lossy(&bytes).into_owned()
        }
    };
    let t = text.trim();
    (!t.is_empty()).then(|| t.chars().take(12_000).collect())
}

pub fn pdf_text(path: &Path) -> Option<String> {
    let doc = lopdf::Document::load(path).ok()?;
    let pages: Vec<u32> = doc.get_pages().keys().copied().collect();
    let mut out = String::new();
    for p in pages {
        if let Ok(t) = doc.extract_text(&[p]) {
            out += &t;
            out.push('\n');
        }
        if out.len() > 40_000 {
            break;
        }
    }
    Some(out)
}

/// Text of an Office Open XML file (the XML parts, tags stripped).
fn office_text(path: &Path, ext: &str) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut zip = zip::ZipArchive::new(file).ok()?;
    let mut names: Vec<String> = (0..zip.len()).filter_map(|i| zip.by_index(i).ok().map(|f| f.name().to_string())).collect();
    names.retain(|n| match ext {
        "docx" => n == "word/document.xml",
        "pptx" => n.starts_with("ppt/slides/slide") && n.ends_with(".xml"),
        "xlsx" => n == "xl/sharedStrings.xml",
        _ => n == "content.xml",
    });
    names.sort_by_key(|n| n.chars().filter(|c| c.is_ascii_digit()).collect::<String>().parse::<u32>().unwrap_or(0));
    let mut out = String::new();
    for n in names {
        let mut f = zip.by_name(&n).ok()?;
        let mut s = String::new();
        use std::io::Read;
        f.read_to_string(&mut s).ok()?;
        // Paragraph and row ends become line breaks.
        let s = s.replace("</w:p>", "\n").replace("</a:p>", "\n").replace("</si>", "\n").replace("</text:p>", "\n");
        out += &strip_tags(&s);
        out.push('\n');
    }
    Some(out)
}

pub fn strip_tags(html: &str) -> String {
    let no_script = Regex::new(r"(?is)<(script|style)[^>]*>.*?</(script|style)>").unwrap().replace_all(html, " ");
    let text = Regex::new(r"(?s)<[^>]*>").unwrap().replace_all(&no_script, "");
    let text = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");
    Regex::new(r"[ \t]+").unwrap().replace_all(&text, " ").lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join("\n")
}

/// A PDF open in the browser (file:// or http), read from its address.
pub async fn read_url_pdf(url: &str) -> Option<String> {
    if let Some(path) = url.strip_prefix("file:///") {
        let p = PathBuf::from(url_decode(path).replace('/', "\\"));
        return read_text(&p).await;
    }
    if !url.starts_with("http") {
        return None;
    }
    let bytes = reqwest::get(url).await.ok()?.bytes().await.ok()?;
    let tmp = std::env::temp_dir().join(format!("clinqy-{}.pdf", uuid::Uuid::new_v4()));
    std::fs::write(&tmp, &bytes).ok()?;
    let t = read_text(&tmp).await;
    let _ = std::fs::remove_file(&tmp);
    t
}

pub fn url_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A path not yet taken: "name 2.ext", "name 3.ext"…
pub fn unique(p: &Path) -> PathBuf {
    if !p.exists() {
        return p.to_path_buf();
    }
    let stem = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = p.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    let dir = p.parent().map(Path::to_path_buf).unwrap_or_default();
    (2..).map(|n| dir.join(format!("{stem} {n}{ext}"))).find(|c| !c.exists()).unwrap()
}

pub fn list(folder: &Path, sort: &str, limit: usize) -> Result<String, String> {
    let rd = std::fs::read_dir(folder).map_err(|e| format!("can't list {}: {e}", folder.display()))?;
    let mut rows: Vec<(String, bool, u64, std::time::SystemTime)> = rd
        .flatten()
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            Some((e.file_name().to_string_lossy().into_owned(), m.is_dir(), m.len(), m.modified().unwrap_or(std::time::UNIX_EPOCH)))
        })
        .collect();
    match sort {
        "name" => rows.sort_by_key(|a| a.0.to_lowercase()),
        "size" => rows.sort_by_key(|a| std::cmp::Reverse(a.2)),
        _ => rows.sort_by_key(|a| std::cmp::Reverse(a.3)),
    }
    let total = rows.len();
    let lines: Vec<String> = rows
        .iter()
        .take(limit)
        .map(|(n, d, s, t)| {
            let when: chrono::DateTime<chrono::Local> = (*t).into();
            if *d {
                format!("- {n}\\ · {}", when.format("%-d %b %Y %H:%M"))
            } else {
                format!("- {n} · {} · {}", bytes(*s), when.format("%-d %b %Y %H:%M"))
            }
        })
        .collect();
    Ok(format!(
        "{}: {total} items\n{}{}",
        folder.display(),
        lines.join("\n"),
        if total > limit { format!("\n({} more)", total - limit) } else { String::new() }
    ))
}

#[derive(Serialize, Deserialize)]
struct Move {
    from: String,
    to: String,
}

fn moves_dir() -> PathBuf {
    let d = crate::paths::data_dir().join("file-moves");
    let _ = std::fs::create_dir_all(&d);
    d
}

/// Moves/renames each pair (never overwriting), logging the batch for undo.
pub fn apply(pairs: &[(PathBuf, PathBuf)]) -> (Vec<(PathBuf, PathBuf)>, Vec<String>) {
    let (mut done, mut skipped) = (vec![], vec![]);
    for (from, to) in pairs {
        let name = from.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if !from.exists() {
            skipped.push(format!("{name}: not found"));
            continue;
        }
        if from == to {
            continue;
        }
        let dest = unique(to);
        if let Some(parent) = dest.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match std::fs::rename(from, &dest) {
            Ok(_) => done.push((from.clone(), dest)),
            Err(e) => skipped.push(format!("{name}: {e}")),
        }
    }
    if !done.is_empty() {
        let log: Vec<Move> = done.iter().map(|(f, t)| Move { from: f.display().to_string(), to: t.display().to_string() }).collect();
        let name = chrono::Utc::now().format("%Y-%m-%dT%H-%M-%S%.3f").to_string() + ".json";
        let _ = std::fs::write(moves_dir().join(name), serde_json::to_string_pretty(&log).unwrap_or_default());
    }
    (done, skipped)
}

/// Puts the most recent batch back.
pub fn undo() -> Result<String, String> {
    let mut logs: Vec<PathBuf> = std::fs::read_dir(moves_dir())
        .map_err(|e| e.to_string())?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().map(|e| e == "json").unwrap_or(false))
        .collect();
    logs.sort();
    let last = logs.pop().ok_or("nothing to undo")?;
    let moves: Vec<Move> = std::fs::read_to_string(&last).ok().and_then(|t| serde_json::from_str(&t).ok()).ok_or("nothing to undo")?;
    let mut back = 0;
    for m in moves.iter().rev() {
        let (from, to) = (PathBuf::from(&m.from), PathBuf::from(&m.to));
        if to.exists() && !from.exists() {
            if let Some(p) = from.parent() {
                let _ = std::fs::create_dir_all(p);
            }
            if std::fs::rename(&to, &from).is_ok() {
                back += 1;
            }
        }
    }
    let _ = std::fs::remove_file(&last);
    Ok(format!("put back {back} of {} files", moves.len()))
}

/// Top-level files of a folder grouped into subfolders by kind.
pub fn organize_plan(folder: &Path) -> Result<Vec<(PathBuf, PathBuf)>, String> {
    const GROUPS: &[(&str, &[&str])] = &[
        ("PDFs", &["pdf"]),
        ("Images", &["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg", "raw", "psd"]),
        ("Videos", &["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp", "wmv"]),
        ("Audio", &["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg", "wma"]),
        ("Documents", &["doc", "docx", "rtf", "txt", "md", "odt", "epub"]),
        ("Spreadsheets", &["xls", "xlsx", "csv", "tsv", "ods"]),
        ("Presentations", &["ppt", "pptx", "odp"]),
        ("Archives", &["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
        ("Installers", &["exe", "msi", "msix", "appx", "iso"]),
        ("Code", &["py", "js", "ts", "json", "html", "css", "java", "c", "cpp", "go", "rs", "ipynb", "sh", "ps1", "pem"]),
    ];
    let rd = std::fs::read_dir(folder).map_err(|e| format!("can't read {}: {e}", folder.display()))?;
    Ok(rd
        .flatten()
        .filter(|e| e.metadata().map(|m| m.is_file()).unwrap_or(false))
        .filter_map(|e| {
            let p = e.path();
            let ext = p.extension()?.to_string_lossy().to_lowercase();
            if ["crdownload", "download", "part", "tmp"].contains(&ext.as_str()) || e.file_name().to_string_lossy().starts_with('.') {
                return None;
            }
            let group = GROUPS.iter().find(|g| g.1.contains(&ext.as_str())).map(|g| g.0).unwrap_or("Other");
            Some((p.clone(), folder.join(group).join(e.file_name())))
        })
        .collect())
}

// MARK: - Tables

/// A small RFC 4180 parser: quoted fields, doubled quotes, newlines inside quotes.
pub fn parse_delimited(text: &str, sep: char) -> Vec<Vec<String>> {
    let (mut rows, mut row, mut field, mut quoted) = (vec![], vec![], String::new(), false);
    let text = text.replace("\r\n", "\n");
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if quoted {
            if c == '"' {
                if chars.peek() == Some(&'"') {
                    field.push('"');
                    chars.next();
                } else {
                    quoted = false;
                }
            } else {
                field.push(c);
            }
        } else if c == '"' && field.is_empty() {
            quoted = true;
        } else if c == sep {
            row.push(std::mem::take(&mut field));
        } else if c == '\n' {
            row.push(std::mem::take(&mut field));
            if row.iter().any(|f: &String| !f.is_empty()) {
                rows.push(std::mem::take(&mut row));
            } else {
                row.clear();
            }
        } else {
            field.push(c);
        }
    }
    row.push(field);
    if row.iter().any(|f| !f.is_empty()) {
        rows.push(row);
    }
    rows
}

pub fn read_delimited(path: &Path) -> Option<Vec<Vec<String>>> {
    let bytes = std::fs::read(path).ok()?;
    let text = String::from_utf8_lossy(&bytes).trim_start_matches('\u{feff}').to_string();
    let tsv = path.extension().map(|e| e.eq_ignore_ascii_case("tsv")).unwrap_or(false) || (!text.contains(',') && text.contains('\t'));
    Some(parse_delimited(&text, if tsv { '\t' } else { ',' }))
}

pub fn to_csv(rows: &[Vec<String>]) -> String {
    rows.iter()
        .map(|r| {
            r.iter()
                .map(|f| if f.contains([',', '"', '\n', '\r']) { format!("\"{}\"", f.replace('"', "\"\"")) } else { f.clone() })
                .collect::<Vec<_>>()
                .join(",")
        })
        .collect::<Vec<_>>()
        .join("\r\n")
        + "\r\n"
}

pub fn to_tsv(rows: &[Vec<String>]) -> String {
    rows.iter().map(|r| r.iter().map(|f| f.replace(['\t', '\n'], " ")).collect::<Vec<_>>().join("\t")).collect::<Vec<_>>().join("\n")
}

/// A web page's tables (via the extension) as text: "Table 1 “Invoices” — 12 rows:" + rows.
pub fn describe_tables(tables: &[serde_json::Value]) -> String {
    tables
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let rows: Vec<Vec<String>> = t["rows"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .map(|r| r.as_array().map(|c| c.iter().map(|x| x.as_str().unwrap_or("").to_string()).collect()).unwrap_or_default())
                        .collect()
                })
                .unwrap_or_default();
            let name = t["name"].as_str().filter(|n| !n.is_empty()).map(|n| format!("“{n}”")).unwrap_or_default();
            let more = t["more"].as_i64().filter(|m| *m > 0).map(|m| format!(" (+{m} more rows not shown)")).unwrap_or_default();
            format!(
                "Table {} {name} — {} rows{more}:\n{}",
                i + 1,
                rows.len(),
                rows.iter().map(|r| r.join(" | ")).collect::<Vec<_>>().join("\n")
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Writes rows to a CSV file (appending when asked; a header row that matches isn't repeated).
pub fn write_csv(rows: &[Vec<String>], path: &Path, append: bool) -> Result<(String, PathBuf), String> {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if append && path.exists() {
        let existing = read_delimited(path).unwrap_or_default();
        let skip_header = existing.first().zip(rows.first()).map(|(a, b)| a == b).unwrap_or(false);
        let body = to_csv(if skip_header { &rows[1..] } else { rows });
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new().append(true).open(path).map_err(|e| e.to_string())?;
        f.write_all(body.as_bytes()).map_err(|e| e.to_string())?;
        return Ok((format!("added {} rows to {}", rows.len() - skip_header as usize, crate::paths::display(path)), path.to_path_buf()));
    }
    let dest = if append { path.to_path_buf() } else { unique(path) };
    // A BOM so Excel reads it as UTF-8 (₹, names in other scripts).
    std::fs::write(&dest, format!("\u{feff}{}", to_csv(rows))).map_err(|e| e.to_string())?;
    Ok((format!("wrote {} rows to {}", rows.len(), crate::paths::display(&dest)), dest))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_round_trip() {
        let rows = vec![vec!["a".to_string(), "b,c".into()], vec!["x\"y".into(), "".into()]];
        let back = parse_delimited(&to_csv(&rows), ',');
        assert_eq!(back[0], rows[0]);
        assert_eq!(back[1][0], "x\"y");
    }

    #[test]
    fn strips_html() {
        assert_eq!(strip_tags("<p>Hi&nbsp;<b>there</b></p><script>x()</script>"), "Hi there");
    }
}
