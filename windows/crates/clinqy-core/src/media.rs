//! Video and audio jobs through ffmpeg (combine, trim, compress, to_mp4, to_audio, info), in the background with
//! progress. ffmpeg is found on PATH, in WinGet's links, or via FFMPEG_PATH; without it the job says how to get it.

use crate::files::{bytes, unique};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};

fn find(name: &str) -> Option<PathBuf> {
    if let Some(p) = crate::config::value(&format!("{}_PATH", name.to_uppercase())) {
        return Some(PathBuf::from(p));
    }
    let exe = format!("{name}.exe");
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        dirs.push(PathBuf::from(local).join("Microsoft").join("WinGet").join("Links"));
    }
    dirs.push(PathBuf::from(r"C:\ffmpeg\bin"));
    dirs.into_iter().map(|d| d.join(&exe)).find(|p| p.is_file())
}

fn seconds(v: &serde_json::Value) -> Option<f64> {
    if let Some(n) = v.as_f64() {
        return Some(n);
    }
    let s = v.as_str()?.trim();
    let parts: Vec<f64> = s.split(':').map(|p| p.parse::<f64>()).collect::<Result<_, _>>().ok()?;
    Some(parts.iter().fold(0.0, |acc, p| acc * 60.0 + p))
}

async fn duration(ffprobe: Option<&Path>, file: &Path) -> Option<f64> {
    let probe = ffprobe?;
    let mut command = tokio::process::Command::new(probe);
    #[cfg(windows)]
    command.creation_flags(crate::session::CREATE_NO_WINDOW);
    let out =
        command.args(["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1"]).arg(file).output().await.ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse().ok()
}

fn beside(p: &Path, suffix: &str, ext: &str) -> PathBuf {
    let stem = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "media".into());
    unique(&p.with_file_name(format!("{stem}-{suffix}.{ext}")))
}

/// Runs one job; `progress` gets 0…1 as ffmpeg reports time.
pub async fn run(
    op: &str,
    files: &[PathBuf],
    opts: &serde_json::Map<String, serde_json::Value>,
    progress: impl Fn(f64) + Send + Sync,
) -> Result<String, String> {
    let ffmpeg = find("ffmpeg")
        .ok_or("ffmpeg isn't installed. Install it once with `winget install Gyan.FFmpeg` (or set FFMPEG_PATH), then try again")?;
    let ffprobe = find("ffprobe");
    let first = files.first().ok_or("media needs files")?;
    for f in files {
        if !f.exists() {
            return Err(format!("no such file: {}", f.display()));
        }
    }
    let out = opts.get("out").and_then(|v| v.as_str()).map(crate::paths::expand);
    let ext = first.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_else(|| "mp4".into());
    let mut args: Vec<String> = vec!["-hide_banner".into(), "-y".into(), "-progress".into(), "pipe:1".into(), "-nostats".into()];
    let mut list_file: Option<PathBuf> = None;
    let mut total = duration(ffprobe.as_deref(), first).await.unwrap_or(0.0);
    let target: PathBuf;
    match op {
        "info" => {
            let mut lines = vec![];
            for f in files {
                let size = std::fs::metadata(f).map(|m| m.len()).unwrap_or(0);
                let d = duration(ffprobe.as_deref(), f)
                    .await
                    .map(|d| format!("{}:{:02}", (d / 60.0) as u64, (d % 60.0) as u64))
                    .unwrap_or_else(|| "?".into());
                lines.push(format!("{}: {d} long, {}", crate::paths::display(f), bytes(size)));
            }
            return Ok(lines.join("\n"));
        }
        "combine" | "merge" | "concat" => {
            if files.len() < 2 {
                return Err("combine needs at least two files".into());
            }
            let list = std::env::temp_dir().join(format!("clinqy-concat-{}.txt", uuid::Uuid::new_v4()));
            let body: String = files.iter().map(|f| format!("file '{}'\n", f.display().to_string().replace('\'', "'\\''"))).collect();
            std::fs::write(&list, body).map_err(|e| e.to_string())?;
            let mut sum = 0.0;
            for f in files {
                sum += duration(ffprobe.as_deref(), f).await.unwrap_or(0.0);
            }
            total = sum;
            target = out.unwrap_or_else(|| beside(first, "combined", &ext));
            args.extend(["-f", "concat", "-safe", "0", "-i"].map(String::from));
            args.push(list.display().to_string());
            args.extend(["-c", "copy"].map(String::from));
            list_file = Some(list);
        }
        "trim" | "cut" => {
            let start = opts.get("start").and_then(seconds).unwrap_or(0.0);
            let end = opts.get("end").and_then(seconds);
            target = out.unwrap_or_else(|| beside(first, "trimmed", &ext));
            args.extend(["-ss".into(), format!("{start}"), "-i".into(), first.display().to_string()]);
            if let Some(e) = end {
                if e <= start {
                    return Err("trim's end comes before its start".into());
                }
                args.extend(["-t".into(), format!("{}", e - start)]);
                total = e - start;
            }
            args.extend(["-c", "copy"].map(String::from));
        }
        "compress" => {
            let crf = match opts.get("level").and_then(|v| v.as_str()).unwrap_or("recommended") {
                "light" => "23",
                "extreme" => "32",
                _ => "28",
            };
            target = out.unwrap_or_else(|| beside(first, "compressed", "mp4"));
            args.extend(["-i".into(), first.display().to_string()]);
            args.extend(
                ["-c:v", "libx264", "-preset", "medium", "-crf", crf, "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
                    .map(String::from),
            );
        }
        "to_mp4" | "convert" => {
            target = out.unwrap_or_else(|| beside(first, "converted", "mp4"));
            args.extend(["-i".into(), first.display().to_string()]);
            args.extend(["-c:v", "libx264", "-crf", "23", "-c:a", "aac", "-movflags", "+faststart"].map(String::from));
        }
        "to_audio" | "extract_audio" => {
            target = out.unwrap_or_else(|| beside(first, "audio", "m4a"));
            args.extend(["-i".into(), first.display().to_string()]);
            args.extend(["-vn", "-c:a", "aac", "-b:a", "192k"].map(String::from));
        }
        other => return Err(format!("media op {other:?}: combine, trim, compress, to_mp4, to_audio or info")),
    }
    args.push(target.display().to_string());
    let mut command = tokio::process::Command::new(&ffmpeg);
    #[cfg(windows)]
    command.creation_flags(crate::session::CREATE_NO_WINDOW);
    let mut child = command
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("couldn't start ffmpeg: {e}"))?;
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let err_task = tokio::spawn(async move {
        let mut lines = BufReader::new(stderr).lines();
        let mut tail = vec![];
        while let Ok(Some(l)) = lines.next_line().await {
            tail.push(l);
            if tail.len() > 20 {
                tail.remove(0);
            }
        }
        tail.join("\n")
    });
    let mut lines = BufReader::new(stdout).lines();
    while let Ok(Some(l)) = lines.next_line().await {
        if let Some(us) = l.strip_prefix("out_time_us=").or_else(|| l.strip_prefix("out_time_ms=")) {
            if let (Ok(v), true) = (us.trim().parse::<f64>(), total > 0.0) {
                progress((v / 1e6 / total).clamp(0.0, 1.0));
            }
        }
    }
    let status = child.wait().await.map_err(|e| e.to_string())?;
    let err = err_task.await.unwrap_or_default();
    if let Some(l) = list_file {
        let _ = std::fs::remove_file(l);
    }
    if !status.success() {
        let _ = std::fs::remove_file(&target);
        // Clips that don't match can't be joined without re-encoding.
        if op.starts_with("comb") || op == "merge" || op == "concat" {
            return Err(format!("ffmpeg couldn't join them as they are (different formats?): {}", err.lines().last().unwrap_or("")));
        }
        return Err(format!("ffmpeg failed: {}", err.lines().last().unwrap_or("")));
    }
    let size = std::fs::metadata(&target).map(|m| m.len()).unwrap_or(0);
    let length = duration(ffprobe.as_deref(), &target)
        .await
        .map(|d| format!(", {}:{:02} long", (d / 60.0) as u64, (d % 60.0) as u64))
        .unwrap_or_default();
    Ok(format!("saved {} ({}{length})", crate::paths::display(&target), bytes(size)))
}
