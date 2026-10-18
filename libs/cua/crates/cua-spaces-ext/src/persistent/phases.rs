// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

//! Two small registries that make an agent's join fast: the members being
//! served right now (a member is served by one task at a time), and the
//! prewarms in flight (a start waits for the install a prewarm already runs
//! instead of repeating it).

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

/// Longest one member's delivery may take inside the supervisor.
pub(crate) const DISPATCH_BUDGET: Duration = Duration::from_secs(60);

pub(crate) fn now_ms() -> u64 {
    cua_volume::now_ms()
}

// --- one task per member ---------------------------------------------------

fn serving() -> &'static Mutex<HashSet<String>> {
    static S: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    S.get_or_init(Default::default)
}

/// Held while a member's queued tasks are being served.
pub(crate) struct ServingGuard(String);

impl ServingGuard {
    /// `None` when `member` is already being served.
    pub(crate) fn take(dir: &Path, member: &str) -> Option<ServingGuard> {
        let key = format!("{}\u{0}{member}", dir.display());
        let taken = serving().lock().ok()?.insert(key.clone());
        taken.then(|| ServingGuard(key))
    }
}

impl Drop for ServingGuard {
    fn drop(&mut self) {
        if let Ok(mut s) = serving().lock() {
            s.remove(&self.0);
        }
    }
}

// --- prewarm ---------------------------------------------------------------

fn prewarms() -> &'static Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>> {
    static P: OnceLock<Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>> = OnceLock::new();
    P.get_or_init(Default::default)
}

fn prewarm_key(dir: &Path, space: &str, harness: &str) -> String {
    format!("{}\u{0}{space}\u{0}{harness}", dir.display())
}

/// The lock a prewarm of `harness` in `space` holds while it runs.
pub(crate) fn prewarm_lock(dir: &Path, space: &str, harness: &str) -> Arc<tokio::sync::Mutex<()>> {
    prewarms()
        .lock()
        .expect("prewarms")
        .entry(prewarm_key(dir, space, harness))
        .or_default()
        .clone()
}

/// Waits (up to `max`) for a prewarm of `harness` in `space` that is running
/// now, so a start does not install what it is installing.
pub(crate) async fn wait_for_prewarm(dir: &Path, space: &str, harness: &str, max: Duration) {
    let lock = prewarm_lock(dir, space, harness);
    let _ = tokio::time::timeout(max, lock.lock()).await;
}

// --- the local record ----------------------------------------------------------

fn sink() -> &'static Mutex<Option<std::path::PathBuf>> {
    static S: OnceLock<Mutex<Option<std::path::PathBuf>>> = OnceLock::new();
    S.get_or_init(Default::default)
}

/// Keeps every step this process reports in `<dir>/phases.jsonl`, one JSON
/// line each (`ts_ms`, `run`, `phase`, `ms` since the message, `cold`,
/// `harness`), so a bench or a person can read how long a join took. The
/// newest lines matter: the file is cut to its last 2000 lines when it
/// passes 1 MiB.
pub(crate) fn set_sink(dir: &Path) {
    if let Ok(mut s) = sink().lock() {
        *s = Some(dir.join("phases.jsonl"));
    }
}

fn record(run: &str, phase: &str, ms: u64, cold: bool, harness: &str) {
    let Some(path) = sink().lock().ok().and_then(|s| s.clone()) else {
        return;
    };
    let line = serde_json::json!({
        "ts_ms": now_ms(), "run": run, "phase": phase, "ms": ms, "cold": cold, "harness": harness,
    });
    use std::io::Write as _;
    if let Ok(meta) = std::fs::metadata(&path)
        && meta.len() > 1 << 20
        && let Ok(text) = std::fs::read_to_string(&path)
    {
        let keep: Vec<&str> = text.lines().rev().take(2000).collect();
        let kept = keep.into_iter().rev().collect::<Vec<_>>().join("\n");
        let _ = std::fs::write(&path, format!("{kept}\n"));
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// A step of a join that the local record keeps: `ms` since the message.
pub(crate) fn local(run: &str, phase: &str, ms: u64, cold: bool, harness: &str) {
    record(run, phase, ms, cold, harness);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_task_serves_a_member_at_a_time() {
        let dir = Path::new("/tmp/phases-test");
        let a = ServingGuard::take(dir, "claude").expect("first");
        assert!(ServingGuard::take(dir, "claude").is_none());
        assert!(ServingGuard::take(dir, "hermes").is_some());
        drop(a);
        assert!(ServingGuard::take(dir, "claude").is_some());
    }

    /// Every step of a join is kept in the local record.
    #[test]
    fn the_local_record_keeps_every_step() {
        let dir = tempfile::tempdir().unwrap();
        set_sink(dir.path());
        let file = dir.path().join("phases.jsonl");
        local("run-a", "delivered", 12, false, "claude-code");
        local("run-a", "first_token_seen", 840, false, "claude-code");
        let lines: Vec<serde_json::Value> = std::fs::read_to_string(&file)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["phase"], "delivered");
        assert_eq!(lines[0]["ms"], 12);
        assert_eq!(lines[1]["phase"], "first_token_seen");
        assert_eq!(lines[1]["harness"], "claude-code");
        assert!(lines[1]["ts_ms"].as_u64().unwrap() > 0);
    }
}
