//! Running and unread desktop agent tasks for the Windows companion.
//!
//! This ports the macOS desktop card pipeline:
//! - Antigravity unread follows `AntigravityUnreadTracker`; running, waiting,
//!   activity and background tasks follow `antigravityRunningTasks` and
//!   `AntigravityActivityReader`.
//! - Codex unread comes from Codex Desktop's own list for the signed-in
//!   identity; running follows `CodexTurnStateReader`.
//! - `DesktopUnreadTaskMonitor` semantics on top: tasks an app marks read
//!   before the user saw them are held until a visit of `READ_DWELL_MS`, and a
//!   task opened from TokenBar is hidden for `READ_LAG_MS` unless a newer turn
//!   finishes.
//! - `UnreadWidgetPublisher` read history for the "recently read" rows.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;

const QUIET_LIMIT_MS: i64 = 30 * 60 * 1000;
const STATUS_CHECK_WINDOW_MS: i64 = 6 * 60 * 60 * 1000;
const NO_ANNOTATION_WINDOW_MS: i64 = 7 * 24 * 60 * 60 * 1000;
const OPEN_SWITCH_LAG_MS: i64 = 10_000;
const CODEX_RECENT_WINDOW_MS: i64 = 24 * 60 * 60 * 1000;
const READ_DWELL_MS: i64 = 3_000;
const READ_LAG_MS: i64 = 60_000;
const VISIT_HISTORY_MS: i64 = 4 * 60 * 60 * 1000;
const HOLD_LIMIT_MS: i64 = 24 * 60 * 60 * 1000;
const FINISH_GRACE_MS: i64 = 3_000;
const RECENT_LIMIT: usize = 2;
const READ_HISTORY_LIMIT: usize = 10;
const MAX_SCAN_BYTES: u64 = 32 * 1024 * 1024;
const MAX_TEXT_CHARS: usize = 160;

const PLATFORMS: [&str; 2] = ["antigravity", "codex"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopUnreadTask {
    pub id: String,
    pub platform: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_label: Option<String>,
    pub completed_at_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_user_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_reply_preview: Option<String>,
    /// What the conversation still runs in the background after its turn ended.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background_activity: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopRunningTask {
    pub id: String,
    pub platform: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_label: Option<String>,
    pub started_at_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_step: Option<String>,
    pub is_background: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopRecentTask {
    pub id: String,
    pub platform: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_label: Option<String>,
    pub read_at_ms: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopPlatformCounts {
    pub running: usize,
    pub background: usize,
    pub unread: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopTaskSnapshot {
    pub generated_at_ms: i64,
    pub running: Vec<DesktopRunningTask>,
    pub background: Vec<DesktopRunningTask>,
    pub unread: Vec<DesktopUnreadTask>,
    pub recent: Vec<DesktopRecentTask>,
    pub by_platform: BTreeMap<String, DesktopPlatformCounts>,
}

fn task_key(platform: &str, id: &str) -> String {
    format!("{platform}/{id}")
}

// ---------------------------------------------------------------------------
// Antigravity unread tracker (port of the macOS AntigravityUnreadTracker)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
struct AgySession {
    id: String,
    title: Option<String>,
    preview: Option<String>,
    workspace_path: Option<String>,
    last_modified_ms: Option<i64>,
    last_modified_s: i64,
    last_user_input_ms: Option<i64>,
    last_user_view_ms: Option<i64>,
    last_user_view_s: Option<i64>,
    annotation_modified_ms: Option<i64>,
    has_annotation: bool,
    marked_as_unread: bool,
    archived: bool,
    killed: bool,
    active_status: bool,
    not_fully_idle: bool,
    foreground_subagents: bool,
    background_subagents: bool,
    subagent_activity: Option<String>,
    subagent_started_ms: Option<i64>,
}

impl AgySession {
    /// Latest moment the user looked at (and optionally typed into) the conversation.
    fn focus_ms(&self, including_input: bool) -> i64 {
        let view = self.last_user_view_ms.unwrap_or(0);
        if including_input {
            view.max(self.last_user_input_ms.unwrap_or(0))
        } else {
            view
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AgyProgress {
    last_modified_seconds: i64,
    is_working: bool,
    last_focus_millis: Option<i64>,
}

/// The conversation Antigravity's window started showing, or `None` for anything else.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct FocusChange {
    session_id: Option<String>,
    at_ms: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AgyTrackerState {
    progress: BTreeMap<String, AgyProgress>,
    viewed_seconds: BTreeMap<String, i64>,
    /// `last_user_view_time` values written while the user did not actually view the conversation.
    unseen_view_millis: BTreeMap<String, i64>,
    waiting_unread_ids: std::collections::BTreeSet<String>,
    shown_session_id: Option<String>,
    focus_changes: Vec<FocusChange>,
}

#[derive(Debug, Clone)]
struct PendingOpen {
    id: String,
    at_ms: i64,
    baseline_view_ms: i64,
    switched_at_ms: Option<i64>,
}

#[derive(Debug, Default)]
struct AgyTracker {
    state: AgyTrackerState,
    has_baseline: bool,
    pending_open: Option<PendingOpen>,
    waiting: HashSet<String>,
    sessions: HashMap<String, AgySession>,
}

impl AgyTracker {
    fn restore(state: Option<AgyTrackerState>) -> Self {
        Self {
            has_baseline: state.is_some(),
            state: state.unwrap_or_default(),
            ..Self::default()
        }
    }

    fn previous_focus(&self, id: &str) -> i64 {
        self.state
            .progress
            .get(id)
            .and_then(|p| p.last_focus_millis)
            .or_else(|| self.sessions.get(id).map(|s| s.focus_ms(true)))
            .unwrap_or(0)
    }

    fn effective_annotation_view_s(session: &AgySession, unseen: Option<i64>) -> i64 {
        if let Some(unseen) = unseen {
            if session.focus_ms(false) <= unseen {
                return 0;
            }
        }
        session.last_user_view_s.unwrap_or(0)
    }

    fn initial_shown(sessions: &HashMap<String, AgySession>) -> Option<(String, i64)> {
        sessions
            .values()
            .filter(|s| !s.archived && s.focus_ms(true) > 0)
            .max_by_key(|s| {
                (
                    s.focus_ms(true),
                    s.last_user_input_ms.unwrap_or(0),
                    s.annotation_modified_ms.unwrap_or(0),
                )
            })
            .map(|s| (s.id.clone(), s.focus_ms(true)))
    }

    fn record_focus_change(&mut self, id: &str, at_ms: i64, now_ms: i64, force: bool) {
        let changed = self.state.shown_session_id.as_deref() != Some(id);
        let newer_than_last = self
            .state
            .focus_changes
            .last()
            .is_none_or(|c| c.session_id.as_deref() != Some(id) || at_ms > c.at_ms);
        self.state.shown_session_id = Some(id.to_string());
        if !(changed || force || newer_than_last || self.state.focus_changes.is_empty()) {
            return;
        }
        self.state.focus_changes.retain(|c| now_ms - c.at_ms < VISIT_HISTORY_MS);
        self.state.focus_changes.push(FocusChange {
            session_id: Some(id.to_string()),
            at_ms,
        });
    }

    fn is_explicitly_read(&self, id: &str) -> bool {
        let Some(session) = self.sessions.get(id).filter(|s| !s.archived) else {
            return false;
        };
        if session.marked_as_unread || self.state.waiting_unread_ids.contains(id) {
            return false;
        }
        let annotation_s = Self::effective_annotation_view_s(
            session,
            self.state.unseen_view_millis.get(id).copied(),
        );
        annotation_s > 0 && annotation_s >= session.last_modified_s
    }

    fn update(
        &mut self,
        sessions: &HashMap<String, AgySession>,
        foreground_running: &HashSet<String>,
        waiting: &HashSet<String>,
        antigravity_active: bool,
        now_ms: i64,
    ) -> HashSet<String> {
        if let Some(pending) = self.pending_open.as_mut() {
            if now_ms - pending.at_ms >= OPEN_SWITCH_LAG_MS {
                self.pending_open = None;
            } else if pending.switched_at_ms.is_none() {
                if let Some(target) = sessions.get(&pending.id) {
                    let view = target.focus_ms(false);
                    if view > pending.baseline_view_ms {
                        pending.switched_at_ms = Some(view);
                    }
                }
            }
        }
        let pending = self.pending_open.clone();
        let is_open_switch_side_effect = |id: &str, view_ms: i64| -> bool {
            match &pending {
                Some(p) if p.id != id && now_ms - p.at_ms < OPEN_SWITCH_LAG_MS => match p.switched_at_ms {
                    Some(switched) => view_ms <= switched + 100,
                    None => view_ms <= p.at_ms + 3_000,
                },
                _ => false,
            }
        };

        if !self.has_baseline {
            if self.state.shown_session_id.is_none() {
                if let Some((id, at)) = Self::initial_shown(sessions) {
                    self.state.shown_session_id = Some(id.clone());
                    if self.state.focus_changes.is_empty() {
                        self.state.focus_changes.push(FocusChange { session_id: Some(id), at_ms: at });
                    }
                }
            }
        } else {
            for (id, session) in sessions.iter().filter(|(_, s)| !s.archived) {
                let previous_focus = self.previous_focus(id);
                let previous_annotation_s = match self.state.unseen_view_millis.get(id) {
                    Some(&unseen) if previous_focus <= unseen => 0,
                    _ => previous_focus / 1000,
                };
                let previous_viewed =
                    previous_annotation_s.max(self.state.viewed_seconds.get(id).copied().unwrap_or(0));
                let had_unread_turn =
                    session.marked_as_unread || session.last_modified_s > previous_viewed;
                let current_view = session.focus_ms(false);
                if current_view > previous_focus {
                    let is_working = foreground_running.contains(id);
                    let advanced_in_background = !antigravity_active
                        && self.state.progress.get(id).is_some_and(|p| {
                            session.last_modified_s > p.last_modified_seconds
                                || (p.is_working && !is_working)
                        });
                    if is_open_switch_side_effect(id, current_view) || advanced_in_background {
                        if had_unread_turn {
                            let entry = self.state.unseen_view_millis.entry(id.clone()).or_insert(0);
                            *entry = (*entry).max(current_view);
                        }
                    } else {
                        self.state.unseen_view_millis.remove(id);
                        if !session.marked_as_unread {
                            self.state.waiting_unread_ids.remove(id);
                        }
                        if !is_working && session.last_modified_s > 0 {
                            let viewed = self.state.viewed_seconds.entry(id.clone()).or_insert(0);
                            *viewed = (*viewed).max(session.last_modified_s);
                        }
                    }
                }
            }

            let current_shown = self.state.shown_session_id.clone();
            let pending_id = pending.as_ref().map(|p| p.id.clone());
            let mut advanced: Vec<((bool, i64, bool, i64), String, i64)> = sessions
                .values()
                .filter(|s| !s.archived)
                .filter_map(|s| {
                    let millis = s.focus_ms(antigravity_active);
                    if millis == 0 {
                        return None;
                    }
                    let previous = self.previous_focus(&s.id);
                    if millis <= previous
                        || is_open_switch_side_effect(&s.id, millis)
                        || self.state.unseen_view_millis.get(&s.id).is_some_and(|&u| millis <= u)
                    {
                        return None;
                    }
                    let is_pending = pending_id.as_deref() == Some(s.id.as_str());
                    let is_switch = current_shown.as_deref() != Some(s.id.as_str());
                    Some(((is_pending, millis, is_switch, -previous), s.id.clone(), millis))
                })
                .collect();
            advanced.sort_by(|a, b| a.0.cmp(&b.0));
            for (_, id, millis) in advanced {
                self.record_focus_change(&id, millis, now_ms, false);
            }
        }

        let active_shown = if antigravity_active {
            self.state
                .shown_session_id
                .clone()
                .or_else(|| Self::initial_shown(sessions).map(|(id, _)| id))
        } else {
            None
        };
        for id in waiting.difference(&self.waiting) {
            if active_shown.as_deref() != Some(id.as_str()) {
                self.state.waiting_unread_ids.insert(id.clone());
            }
        }
        self.state.waiting_unread_ids.retain(|id| {
            let Some(session) = sessions.get(id) else {
                return false;
            };
            if !waiting.contains(id) {
                return false;
            }
            if session.marked_as_unread {
                return true;
            }
            let annotation_s = Self::effective_annotation_view_s(
                session,
                self.state.unseen_view_millis.get(id).copied(),
            );
            let viewed = annotation_s.max(self.state.viewed_seconds.get(id).copied().unwrap_or(0));
            viewed < session.last_modified_s
        });
        if let Some(shown) = &active_shown {
            self.state.waiting_unread_ids.remove(shown);
        }

        if self.has_baseline && antigravity_active {
            if let Some(shown_id) = &active_shown {
                if let Some(shown) = sessions.get(shown_id) {
                    let is_working = foreground_running.contains(shown_id);
                    let advanced = self.state.progress.get(shown_id).map_or(true, |p| {
                        shown.last_modified_s > p.last_modified_seconds || (p.is_working && !is_working)
                    });
                    if (!is_working || advanced) && shown.last_modified_s > 0 {
                        let viewed = self.state.viewed_seconds.entry(shown_id.clone()).or_insert(0);
                        *viewed = (*viewed).max(shown.last_modified_s);
                        self.state.unseen_view_millis.remove(shown_id);
                    }
                }
            }
        }

        self.sessions = sessions.clone();
        self.waiting = waiting.clone();
        self.state.progress = sessions
            .iter()
            .map(|(id, s)| {
                (
                    id.clone(),
                    AgyProgress {
                        last_modified_seconds: s.last_modified_s,
                        is_working: foreground_running.contains(id),
                        last_focus_millis: Some(s.focus_ms(true)),
                    },
                )
            })
            .collect();
        let viewed_snapshot = self.state.viewed_seconds.clone();
        self.state.unseen_view_millis.retain(|id, unseen| {
            let Some(session) = sessions.get(id).filter(|s| !s.archived) else {
                return false;
            };
            let view = session.focus_ms(false);
            view > 0
                && view <= *unseen
                && viewed_snapshot.get(id).copied().unwrap_or(0) < session.last_modified_s
        });
        let unseen_snapshot = self.state.unseen_view_millis.clone();
        self.state.viewed_seconds.retain(|id, viewed| {
            let Some(session) = sessions.get(id).filter(|s| !s.archived) else {
                return false;
            };
            Self::effective_annotation_view_s(session, unseen_snapshot.get(id).copied()) < *viewed
        });
        self.state.focus_changes.retain(|c| now_ms - c.at_ms < VISIT_HISTORY_MS);
        self.has_baseline = true;

        sessions
            .iter()
            .filter(|(_, s)| !s.archived)
            .filter_map(|(id, session)| {
                if session.marked_as_unread || self.state.waiting_unread_ids.contains(id) {
                    return Some(id.clone());
                }
                if foreground_running.contains(id) {
                    return None;
                }
                if !session.has_annotation {
                    let recent = session
                        .last_modified_ms
                        .is_some_and(|m| now_ms - m < NO_ANNOTATION_WINDOW_MS);
                    if !recent {
                        return None;
                    }
                }
                let annotation_s = Self::effective_annotation_view_s(
                    session,
                    self.state.unseen_view_millis.get(id).copied(),
                );
                let viewed = annotation_s.max(self.state.viewed_seconds.get(id).copied().unwrap_or(0));
                (session.last_modified_s > viewed).then(|| id.clone())
            })
            .collect()
    }

    /// The user opened (or dismissed) the conversation from TokenBar.
    fn mark_viewed(&mut self, id: &str, effective_ms: i64, now_ms: i64, open_switch: bool) {
        let modified = self.sessions.get(id).map_or(0, |s| s.last_modified_s);
        let viewed = self.state.viewed_seconds.entry(id.to_string()).or_insert(0);
        *viewed = (*viewed).max(modified.max(effective_ms.div_euclid(1000)));
        self.state.unseen_view_millis.remove(id);
        self.state.waiting_unread_ids.remove(id);
        if open_switch {
            let baseline = self.sessions.get(id).map_or(0, |s| s.focus_ms(false));
            self.pending_open = Some(PendingOpen {
                id: id.to_string(),
                at_ms: now_ms,
                baseline_view_ms: baseline,
                switched_at_ms: None,
            });
            self.record_focus_change(id, now_ms, now_ms, true);
        }
    }
}

// ---------------------------------------------------------------------------
// Hold / read-lag layer (port of the macOS DesktopUnreadTaskMonitor)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy)]
struct Visit {
    start_ms: i64,
    end_ms: Option<i64>,
}

#[derive(Debug, Clone)]
struct HeldTask {
    task: DesktopUnreadTask,
    since_ms: i64,
}

// ---------------------------------------------------------------------------
// Monitor
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct PersistedState {
    antigravity: Option<AgyTrackerState>,
    /// Tasks dismissed in TokenBar ("全部已读" / ×), keyed by `platform/id`, with the
    /// completion time they were dismissed at. A newer turn shows the task again.
    dismissed: BTreeMap<String, i64>,
    read_history: Vec<DesktopRecentTask>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FileStamp {
    modified_ms: i64,
    len: u64,
}

#[derive(Debug, Clone, Default)]
struct PbtxtAnnotation {
    title: Option<String>,
    last_user_view_ms: Option<i64>,
    last_user_view_s: Option<i64>,
    marked_as_unread: bool,
    archived: bool,
}

#[derive(Debug, Clone)]
struct CodexThread {
    id: String,
    title: Option<String>,
    cwd: Option<String>,
    rollout_path: Option<String>,
    updated_at_ms: i64,
}

#[derive(Debug, Clone, Default)]
struct AppState {
    running: bool,
    launched_at_ms: Option<i64>,
}

pub struct DesktopTaskMonitor {
    state_path: Option<PathBuf>,
    agy: AgyTracker,
    dismissed: BTreeMap<String, i64>,
    read_history: Vec<DesktopRecentTask>,
    last_saved: Vec<u8>,

    foreground_platform: Option<String>,
    apps: HashMap<String, AppState>,
    visits: HashMap<String, Vec<Visit>>,
    reported: HashMap<String, Vec<DesktopUnreadTask>>,
    held: HashMap<String, HashMap<String, HeldTask>>,
    existing: HashMap<String, Option<HashSet<String>>>,
    opened_at: HashMap<String, HashMap<String, i64>>,
    opens: HashMap<String, Vec<(String, i64)>>,
    running_ids: HashMap<String, HashSet<String>>,
    previous: DesktopTaskSnapshot,
    finished_turns: HashMap<String, (DesktopRecentTask, i64)>,

    pbtxt_cache: HashMap<PathBuf, (FileStamp, PbtxtAnnotation)>,
    agy_turns: HashMap<PathBuf, AgyTurnProgress>,
    agy_backgrounds: HashMap<PathBuf, AgyBackgroundProgress>,
    codex_turns: HashMap<PathBuf, CodexTurnProgress>,
    codex_previews: HashMap<PathBuf, (FileStamp, CodexPreview)>,
    codex_unread_cache: Option<(PathBuf, FileStamp, HashSet<String>)>,
    codex_activity_ms: HashMap<String, i64>,
    codex_identity_cache: Option<(PathBuf, Option<FileStamp>, Option<String>)>,
}

impl Default for DesktopTaskMonitor {
    fn default() -> Self {
        Self::new(None)
    }
}

impl DesktopTaskMonitor {
    pub fn new(state_path: Option<PathBuf>) -> Self {
        let persisted = state_path
            .as_ref()
            .and_then(|p| fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice::<PersistedState>(&bytes).ok());
        let last_saved = persisted
            .as_ref()
            .and_then(|p| serde_json::to_vec(p).ok())
            .unwrap_or_default();
        let persisted = persisted.unwrap_or_default();
        Self {
            state_path,
            agy: AgyTracker::restore(persisted.antigravity),
            dismissed: persisted.dismissed,
            read_history: persisted.read_history,
            last_saved,
            foreground_platform: None,
            apps: HashMap::new(),
            visits: HashMap::new(),
            reported: HashMap::new(),
            held: HashMap::new(),
            existing: HashMap::new(),
            opened_at: HashMap::new(),
            opens: HashMap::new(),
            running_ids: HashMap::new(),
            previous: DesktopTaskSnapshot::default(),
            finished_turns: HashMap::new(),
            pbtxt_cache: HashMap::new(),
            agy_turns: HashMap::new(),
            agy_backgrounds: HashMap::new(),
            codex_turns: HashMap::new(),
            codex_previews: HashMap::new(),
            codex_unread_cache: None,
            codex_activity_ms: HashMap::new(),
            codex_identity_cache: None,
        }
    }

    /// The app in front changed (`antigravity`, `codex`, `claude`, or `None`).
    /// Mirrors `setFrontmostApplication`: closes the other apps' visits and
    /// opens one for this app.
    pub fn record_foreground(&mut self, platform: Option<&str>, at_ms: i64) {
        let platform = platform.map(str::to_ascii_lowercase);
        for (other, history) in self.visits.iter_mut() {
            if Some(other.as_str()) == platform.as_deref() {
                continue;
            }
            if let Some(last) = history.last_mut() {
                if last.end_ms.is_none() {
                    last.end_ms = Some(at_ms);
                }
            }
        }
        if let Some(platform) = &platform {
            let history = self.visits.entry(platform.clone()).or_default();
            if history.last().is_none_or(|v| v.end_ms.is_some()) {
                history.retain(|v| at_ms - v.end_ms.unwrap_or(at_ms) < VISIT_HISTORY_MS);
                history.push(Visit { start_ms: at_ms, end_ms: None });
            }
        }
        self.foreground_platform = platform;
    }

    /// Whether the desktop app runs, and since when (process start time).
    pub fn set_app_state(&mut self, platform: &str, running: bool, launched_at_ms: Option<i64>) {
        self.apps.insert(platform.to_string(), AppState { running, launched_at_ms });
    }

    fn app(&self, platform: &str) -> AppState {
        // Without information from the host, assume the app runs.
        self.apps.get(platform).cloned().unwrap_or(AppState { running: true, launched_at_ms: None })
    }

    /// A task opened from TokenBar is read once its app shows it, however briefly.
    pub fn mark_opened(&mut self, platform: &str, id: &str, now_ms: i64) {
        let updated = self.known_task(platform, id).map(|t| t.completed_at_ms);
        let effective = now_ms.max(updated.unwrap_or(0));
        self.opened_at.entry(platform.to_string()).or_default().insert(id.to_string(), effective);
        if platform == "antigravity" {
            let opens = self.opens.entry(platform.to_string()).or_default();
            opens.retain(|(_, at)| now_ms - at < VISIT_HISTORY_MS);
            opens.push((id.to_string(), now_ms));
            self.agy.mark_viewed(id, effective, now_ms, true);
        }
        if let Some(held) = self.held.get_mut(platform) {
            held.remove(id);
        }
        self.save_if_changed();
    }

    /// Hides a task without opening it, until a newer turn finishes.
    pub fn dismiss(&mut self, platform: &str, id: &str, now_ms: i64) {
        let completed = self.known_task(platform, id).map_or(now_ms, |t| t.completed_at_ms);
        self.dismissed.insert(task_key(platform, id), completed);
        if platform == "antigravity" {
            self.agy.mark_viewed(id, now_ms, now_ms, false);
        }
        if let Some(held) = self.held.get_mut(platform) {
            held.remove(id);
        }
        self.save_if_changed();
    }

    pub fn dismiss_all(&mut self, now_ms: i64) {
        let unread: Vec<(String, String)> = self
            .previous
            .unread
            .iter()
            .map(|t| (t.platform.clone(), t.id.clone()))
            .collect();
        for (platform, id) in unread {
            self.dismiss(&platform, &id, now_ms);
        }
    }

    fn known_task(&self, platform: &str, id: &str) -> Option<DesktopUnreadTask> {
        self.reported
            .get(platform)
            .and_then(|tasks| tasks.iter().find(|t| t.id == id).cloned())
            .or_else(|| self.held.get(platform).and_then(|h| h.get(id)).map(|h| h.task.clone()))
    }

    pub fn poll(&mut self, codex_root: &Path, antigravity_root: &Path, now_ms: i64) -> DesktopTaskSnapshot {
        let mut active: Vec<DesktopRunningTask> = Vec::new();

        if let Some((unread, existing, running)) = self.collect_antigravity(antigravity_root, now_ms) {
            self.running_ids.insert(
                "antigravity".into(),
                running.iter().filter(|t| !t.is_background).map(|t| t.id.clone()).collect(),
            );
            active.extend(running);
            self.accept("antigravity", unread, Some(existing), now_ms);
        }
        if let Some((unread, running)) = self.collect_codex(codex_root, now_ms) {
            self.running_ids.insert("codex".into(), running.iter().map(|t| t.id.clone()).collect());
            active.extend(running);
            self.accept("codex", unread, None, now_ms);
        }

        let mut unread: Vec<DesktopUnreadTask> = PLATFORMS
            .iter()
            .flat_map(|p| self.publish(p, now_ms))
            .collect();
        let dismissed = &self.dismissed;
        unread.retain(|t| {
            dismissed
                .get(&task_key(&t.platform, &t.id))
                .is_none_or(|&at| t.completed_at_ms > at)
        });

        active.sort_by(|a, b| b.started_at_ms.cmp(&a.started_at_ms).then_with(|| a.id.cmp(&b.id)));
        let unread_keys: HashSet<String> = unread.iter().map(|t| task_key(&t.platform, &t.id)).collect();
        let running: Vec<DesktopRunningTask> = active.iter().filter(|t| !t.is_background).cloned().collect();
        let running_keys: HashSet<String> = running.iter().map(|t| task_key(&t.platform, &t.id)).collect();
        let background: Vec<DesktopRunningTask> = active
            .iter()
            .filter(|t| t.is_background && !unread_keys.contains(&task_key(&t.platform, &t.id)))
            .cloned()
            .collect();
        unread.retain(|t| !running_keys.contains(&task_key(&t.platform, &t.id)));
        for task in unread.iter_mut() {
            task.background_activity = active
                .iter()
                .find(|r| r.is_background && r.platform == task.platform && r.id == task.id)
                .and_then(|r| r.current_step.clone());
        }
        unread.sort_by(|a, b| b.completed_at_ms.cmp(&a.completed_at_ms).then_with(|| a.id.cmp(&b.id)));

        // Drop dismissals that no longer match a reported or held task.
        let live: HashSet<String> = PLATFORMS
            .iter()
            .flat_map(|p| {
                let reported = self.reported.get(*p).into_iter().flatten().map(move |t| task_key(p, &t.id));
                let held = self.held.get(*p).into_iter().flat_map(|h| h.keys()).map(move |id| task_key(p, id));
                reported.chain(held).collect::<Vec<_>>()
            })
            .collect();
        self.dismissed.retain(|key, _| live.contains(key));

        let mut by_platform = BTreeMap::new();
        for platform in PLATFORMS {
            by_platform.insert(platform.to_string(), DesktopPlatformCounts::default());
        }
        for task in &running {
            by_platform.entry(task.platform.clone()).or_default().running += 1;
        }
        for task in &background {
            by_platform.entry(task.platform.clone()).or_default().background += 1;
        }
        for task in &unread {
            by_platform.entry(task.platform.clone()).or_default().unread += 1;
        }

        let mut snapshot = DesktopTaskSnapshot {
            generated_at_ms: now_ms,
            running,
            background,
            unread,
            recent: Vec::new(),
            by_platform,
        };
        snapshot.recent = self.recording_reads(&snapshot, now_ms);
        self.previous = snapshot.clone();
        self.save_if_changed();
        snapshot
    }

    /// Holds the tasks the app no longer reports, unless opened from TokenBar.
    fn accept(&mut self, platform: &str, tasks: Vec<DesktopUnreadTask>, existing: Option<HashSet<String>>, now_ms: i64) {
        let ids: HashSet<String> = tasks.iter().map(|t| t.id.clone()).collect();
        let opened = self.opened_at.entry(platform.to_string()).or_default();
        opened.retain(|_, at| now_ms - *at < READ_LAG_MS);
        let opened = opened.clone();
        let previous = self.reported.get(platform).cloned().unwrap_or_default();
        let held = self.held.entry(platform.to_string()).or_default();
        for task in previous {
            if !ids.contains(&task.id) && !opened.contains_key(&task.id) {
                held.insert(task.id.clone(), HeldTask { task, since_ms: now_ms });
            }
        }
        self.reported.insert(platform.to_string(), tasks);
        self.existing.insert(platform.to_string(), existing);
        self.release_held(platform, now_ms);
    }

    fn release_held(&mut self, platform: &str, now_ms: i64) {
        let Some(held) = self.held.get(platform) else {
            return;
        };
        if held.is_empty() {
            return;
        }
        let focus: Option<Vec<FocusChange>> = (platform == "antigravity"
            && !self.agy.state.focus_changes.is_empty())
        .then(|| self.agy.state.focus_changes.clone());
        let existing = self.existing.get(platform).cloned().flatten();
        let keep: HashMap<String, HeldTask> = held
            .iter()
            .filter(|(id, hold)| {
                now_ms - hold.since_ms < HOLD_LIMIT_MS
                    && existing.as_ref().is_none_or(|e| e.contains(*id))
                    && !self.seen(&hold.task, platform, focus.as_deref(), now_ms)
            })
            .map(|(id, hold)| (id.clone(), hold.clone()))
            .collect();
        self.held.insert(platform.to_string(), keep);
    }

    /// Whether a visit that ended after the task finished read it. Without
    /// focus history, a visit reads every task once it lasts `READ_DWELL_MS`.
    fn seen(&self, task: &DesktopUnreadTask, platform: &str, focus: Option<&[FocusChange]>, now_ms: i64) -> bool {
        if platform == "antigravity" && self.agy.is_explicitly_read(&task.id) {
            return true;
        }
        if platform == "codex"
            && self
                .codex_activity_ms
                .get(&task.id)
                .is_some_and(|&at| at >= task.completed_at_ms)
        {
            return true;
        }
        let finished = task.completed_at_ms;
        self.visits.get(platform).into_iter().flatten().any(|visit| {
            let end = visit.end_ms.unwrap_or(now_ms);
            if end < finished {
                return false;
            }
            match focus {
                None => end - visit.start_ms >= READ_DWELL_MS,
                Some(focus) => self.visit_read(&task.id, platform, visit, focus, now_ms),
            }
        })
    }

    fn was_active_since(&self, platform: &str, since_ms: i64) -> bool {
        self.foreground_platform.as_deref() == Some(platform)
            || (since_ms > 0
                && self
                    .visits
                    .get(platform)
                    .into_iter()
                    .flatten()
                    .any(|v| v.end_ms.unwrap_or(i64::MAX) >= since_ms))
    }

    /// The visit read the session if it showed the session for `READ_DWELL_MS`,
    /// or the user switched to it or away from it.
    fn visit_read(&self, id: &str, platform: &str, visit: &Visit, focus: &[FocusChange], now_ms: i64) -> bool {
        let end = visit.end_ms.unwrap_or(now_ms);
        let mut shown = focus
            .iter()
            .rev()
            .find(|c| c.at_ms <= visit.start_ms - 1000)
            .and_then(|c| c.session_id.clone());
        let mut shown_since = visit.start_ms;
        let mut duration = 0;
        for change in focus.iter().filter(|c| c.at_ms > visit.start_ms - 1000 && c.at_ms <= end) {
            let at = change.at_ms.max(visit.start_ms);
            if shown.as_deref() == Some(id) {
                duration += at - shown_since;
            }
            if (shown.as_deref() == Some(id) || change.session_id.as_deref() == Some(id))
                && !self.is_open_switch(change, platform)
            {
                return true;
            }
            shown = change.session_id.clone();
            shown_since = at;
        }
        if shown.as_deref() == Some(id) {
            duration += end - shown_since;
        }
        duration >= READ_DWELL_MS
    }

    fn is_open_switch(&self, change: &FocusChange, platform: &str) -> bool {
        self.opens.get(platform).into_iter().flatten().any(|(id, at)| {
            (change.session_id.is_none() || change.session_id.as_deref() == Some(id.as_str()))
                && change.at_ms > at - 1000
                && change.at_ms < at + OPEN_SWITCH_LAG_MS
        })
    }

    /// Reported tasks plus held ones that are neither reported again nor
    /// running. Tasks just opened from TokenBar clear unless a newer turn
    /// finished after the click.
    fn publish(&mut self, platform: &str, now_ms: i64) -> Vec<DesktopUnreadTask> {
        let opened = self.opened_at.entry(platform.to_string()).or_default();
        opened.retain(|_, at| now_ms - *at < READ_LAG_MS);
        let opened = opened.clone();
        let reported_all = self.reported.get(platform).cloned().unwrap_or_default();
        let reported: Vec<DesktopUnreadTask> = reported_all
            .iter()
            .filter(|t| opened.get(&t.id).is_none_or(|&at| t.completed_at_ms > at))
            .cloned()
            .collect();
        let mut excluded: HashSet<String> = reported_all.iter().map(|t| t.id.clone()).collect();
        excluded.extend(self.running_ids.get(platform).cloned().unwrap_or_default());
        let held = self.held.entry(platform.to_string()).or_default();
        held.retain(|id, _| !excluded.contains(id) && !opened.contains_key(id));
        reported.into_iter().chain(held.values().map(|h| h.task.clone())).collect()
    }

    /// Port of `UnreadWidgetPublisher.recordingReads`.
    fn recording_reads(&mut self, next: &DesktopTaskSnapshot, now_ms: i64) -> Vec<DesktopRecentTask> {
        let current: HashSet<String> = next
            .unread
            .iter()
            .map(|t| task_key(&t.platform, &t.id))
            .chain(next.running.iter().chain(&next.background).map(|t| task_key(&t.platform, &t.id)))
            .collect();
        for task in self.previous.running.iter().chain(&self.previous.background) {
            let key = task_key(&task.platform, &task.id);
            if current.contains(&key) {
                continue;
            }
            let item = DesktopRecentTask {
                id: task.id.clone(),
                platform: task.platform.clone(),
                title: task.title.clone(),
                workspace_path: task.workspace_path.clone(),
                workspace_label: task.workspace_label.clone(),
                read_at_ms: now_ms,
            };
            self.finished_turns.insert(key, (item, now_ms));
        }
        self.finished_turns.retain(|key, _| !current.contains(key));
        let settled: Vec<DesktopRecentTask> = self
            .finished_turns
            .values()
            .filter(|(_, at)| now_ms - at >= FINISH_GRACE_MS)
            .map(|(item, _)| item.clone())
            .collect();
        for item in &settled {
            self.finished_turns.remove(&task_key(&item.platform, &item.id));
        }
        let mut read: Vec<DesktopRecentTask> = self
            .previous
            .unread
            .iter()
            .filter(|t| !current.contains(&task_key(&t.platform, &t.id)))
            .map(|t| DesktopRecentTask {
                id: t.id.clone(),
                platform: t.platform.clone(),
                title: t.title.clone(),
                workspace_path: t.workspace_path.clone(),
                workspace_label: t.workspace_label.clone(),
                read_at_ms: now_ms,
            })
            .collect();
        read.extend(settled);
        if !read.is_empty() {
            let read_keys: HashSet<String> = read.iter().map(|t| task_key(&t.platform, &t.id)).collect();
            let mut history = read;
            history.extend(
                self.read_history
                    .iter()
                    .filter(|t| !read_keys.contains(&task_key(&t.platform, &t.id)))
                    .cloned(),
            );
            history.truncate(READ_HISTORY_LIMIT);
            self.read_history = history;
        }
        self.read_history
            .iter()
            .filter(|t| !current.contains(&task_key(&t.platform, &t.id)))
            .take(RECENT_LIMIT)
            .cloned()
            .collect()
    }

    fn save_if_changed(&mut self) {
        let Some(path) = self.state_path.clone() else {
            return;
        };
        let persisted = PersistedState {
            antigravity: Some(self.agy.state.clone()),
            dismissed: self.dismissed.clone(),
            read_history: self.read_history.clone(),
        };
        let Ok(bytes) = serde_json::to_vec(&persisted) else {
            return;
        };
        if bytes == self.last_saved {
            return;
        }
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let tmp = path.with_extension("tmp");
        if fs::write(&tmp, &bytes).is_ok() && fs::rename(&tmp, &path).is_ok() {
            self.last_saved = bytes;
        }
    }

    // -- Antigravity ---------------------------------------------------------

    /// Unread tasks, unarchived conversation ids, and running tasks.
    #[allow(clippy::type_complexity)]
    fn collect_antigravity(
        &mut self,
        root: &Path,
        now_ms: i64,
    ) -> Option<(Vec<DesktopUnreadTask>, HashSet<String>, Vec<DesktopRunningTask>)> {
        let sessions = self.read_antigravity_sessions(root)?;
        let brain = root.join("brain");
        let app = self.app("antigravity");
        let mut running = Vec::new();
        let mut foreground_ids = HashSet::new();
        let mut waiting = HashSet::new();
        let mut followed = HashSet::new();

        for session in sessions.values() {
            if session.archived || session.killed || !app.running {
                continue;
            }
            let wants_status_check = session.active_status
                || session.not_fully_idle
                || session.foreground_subagents
                || session.background_subagents
                || self.agy.waiting.contains(&session.id)
                || session
                    .last_modified_ms
                    .is_some_and(|m| now_ms - m < STATUS_CHECK_WINDOW_MS);
            if !wants_status_check {
                continue;
            }
            let transcript = agy_transcript(&brain, &session.id);
            let stamp = file_stamp(&transcript);
            let mut activity = None;
            let mut background_task = None;
            if let Some(stamp) = &stamp {
                followed.insert(transcript.clone());
                let turn = self.agy_turn(&transcript, stamp.len);
                if turn.waiting {
                    waiting.insert(session.id.clone());
                    continue;
                }
                if session.active_status
                    || session.not_fully_idle
                    || session.foreground_subagents
                    || session.background_subagents
                {
                    activity = turn.activity.clone();
                }
                if session.not_fully_idle {
                    if let Some(launched) = app.launched_at_ms {
                        background_task = self.agy_background(&transcript, stamp.len, launched);
                    }
                }
            }
            let latest_activity = session
                .last_modified_ms
                .unwrap_or(0)
                .max(stamp.as_ref().map_or(0, |s| s.modified_ms));
            let title = session_title(session.title.as_deref(), session.preview.as_deref(), "Antigravity 会话");
            let workspace_label = session.workspace_path.as_deref().and_then(workspace_basename).map(str::to_string);
            if (session.active_status || session.foreground_subagents) && now_ms - latest_activity < QUIET_LIMIT_MS {
                foreground_ids.insert(session.id.clone());
                running.push(DesktopRunningTask {
                    id: session.id.clone(),
                    platform: "antigravity".into(),
                    title,
                    workspace_path: session.workspace_path.clone(),
                    workspace_label,
                    started_at_ms: session.last_user_input_ms.or(session.last_modified_ms).unwrap_or(now_ms),
                    current_step: activity.or_else(|| session.subagent_activity.clone()),
                    is_background: false,
                });
            } else if session.not_fully_idle || session.background_subagents {
                let mut parts: Vec<String> = Vec::new();
                if let Some(sub) = &session.subagent_activity {
                    parts.push(sub.clone());
                }
                if let Some(bg) = background_task.as_ref().and_then(|b| b.1.clone()) {
                    parts.push(bg);
                } else if session.subagent_activity.is_none() {
                    if let Some(a) = &activity {
                        parts.push(a.clone());
                    }
                }
                running.push(DesktopRunningTask {
                    id: session.id.clone(),
                    platform: "antigravity".into(),
                    title,
                    workspace_path: session.workspace_path.clone(),
                    workspace_label,
                    started_at_ms: background_task
                        .as_ref()
                        .map(|b| b.0)
                        .or(session.subagent_started_ms)
                        .or(session.last_user_input_ms)
                        .or(session.last_modified_ms)
                        .unwrap_or(now_ms),
                    current_step: (!parts.is_empty()).then(|| parts.join(" · ")),
                    is_background: true,
                });
            }
        }

        let active = self.was_active_since("antigravity", self.previous.generated_at_ms);
        let unread_ids = self.agy.update(&sessions, &foreground_ids, &waiting, active, now_ms);
        let mut unread = Vec::new();
        for id in unread_ids {
            let Some(session) = sessions.get(&id) else {
                continue;
            };
            let transcript = agy_transcript(&brain, &id);
            let turn = file_stamp(&transcript)
                .map(|stamp| {
                    followed.insert(transcript.clone());
                    self.agy_turn(&transcript, stamp.len)
                })
                .unwrap_or_default();
            unread.push(DesktopUnreadTask {
                id: id.clone(),
                platform: "antigravity".into(),
                title: session_title(session.title.as_deref(), turn.prompt.as_deref(), "Antigravity 会话"),
                workspace_path: session.workspace_path.clone(),
                workspace_label: session.workspace_path.as_deref().and_then(workspace_basename).map(str::to_string),
                completed_at_ms: session.last_modified_ms.or(turn.last_ms).unwrap_or(0),
                turn_duration_ms: turn.duration_ms(),
                last_user_prompt: turn.prompt.clone(),
                last_reply_preview: turn
                    .reply
                    .clone()
                    .or_else(|| turn.user_input.clone())
                    .or_else(|| session.preview.as_deref().and_then(|p| reply_summary(p))),
                background_activity: None,
            });
        }
        self.agy_turns.retain(|p, _| followed.contains(p));
        self.agy_backgrounds.retain(|p, _| followed.contains(p));
        let existing = sessions.values().filter(|s| !s.archived).map(|s| s.id.clone()).collect();
        Some((unread, existing, running))
    }

    fn agy_turn(&mut self, path: &Path, len: u64) -> AgyTurn {
        if let Some(known) = self.agy_turns.get(path) {
            if known.offset == len {
                return known.turn.clone();
            }
            if known.offset < len {
                let next = advance_lines(path, known.offset, len, known.clone(), |progress, line| {
                    if line.contains("\"USER_INPUT\"") || line.contains("\"PLANNER_RESPONSE\"") {
                        progress.turn.apply(line);
                    }
                });
                self.agy_turns.insert(path.to_path_buf(), next.clone());
                return next.turn;
            }
        }
        // Collect lines back to the prompt that opened the latest turn.
        let mut collected: Vec<String> = Vec::new();
        let offset = scan_backward(path, len, |line| {
            if !(line.contains("\"USER_INPUT\"") || line.contains("\"PLANNER_RESPONSE\"")) {
                return false;
            }
            collected.push(line.to_string());
            agy_is_prompt(line)
        });
        let mut turn = AgyTurn::default();
        for line in collected.iter().rev() {
            turn.apply(line);
        }
        let progress = AgyTurnProgress { offset, turn };
        self.agy_turns.insert(path.to_path_buf(), progress.clone());
        progress.turn
    }

    fn agy_background(&mut self, path: &Path, len: u64, cutoff_ms: i64) -> Option<(i64, Option<String>)> {
        let known = self
            .agy_backgrounds
            .get(path)
            .filter(|k| k.offset <= len)
            .cloned()
            .unwrap_or_else(|| AgyBackgroundProgress {
                offset: len.saturating_sub(MAX_SCAN_BYTES),
                ..AgyBackgroundProgress::default()
            });
        let known = if known.offset < len {
            advance_lines(path, known.offset, len, known, |progress, line| progress.apply(line))
        } else {
            known
        };
        self.agy_backgrounds.insert(path.to_path_buf(), known.clone());
        let mut running: Vec<&AgyBackgroundTask> =
            known.pending.values().filter(|t| t.started_ms > cutoff_ms).collect();
        running.sort_by_key(|t| t.started_ms);
        let first = running.first()?;
        let activities: Vec<String> = running.iter().filter_map(|t| t.activity.clone()).collect();
        Some((first.started_ms, (!activities.is_empty()).then(|| activities.join(" · "))))
    }

    fn read_antigravity_sessions(&mut self, root: &Path) -> Option<HashMap<String, AgySession>> {
        let db_path = root.join("conversation_summaries.db");
        if !db_path.is_file() {
            return None;
        }
        let conn = Connection::open_with_flags(
            &db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .ok()?;
        let _ = conn.busy_timeout(std::time::Duration::from_millis(500));
        let columns = column_names(&conn, "conversation_summaries");
        if !columns.contains("conversation_id") {
            return None;
        }
        let col = |name: &str| if columns.contains(name) { name.to_string() } else { "NULL".to_string() };

        let mut archived_ids = HashSet::new();
        if let Ok(mut stmt) =
            conn.prepare("SELECT DISTINCT conversation_id FROM conversations_fts WHERE archived != 0")
        {
            if let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(0)) {
                archived_ids.extend(rows.flatten());
            }
        }

        struct Raw {
            id: String,
            title: Option<String>,
            preview: Option<String>,
            step_count: i64,
            last_modified_ms: Option<i64>,
            last_user_input_ms: Option<i64>,
            workspace_path: Option<String>,
            active_status: bool,
            agent_name: Option<String>,
            parent_id: Option<String>,
            nesting_depth: i64,
            not_fully_idle: bool,
            killed: bool,
        }

        let sql = format!(
            "SELECT conversation_id, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {} FROM conversation_summaries",
            col("title"),
            col("preview"),
            col("step_count"),
            col("last_modified_time"),
            col("last_user_input_time"),
            col("workspace_uris"),
            col("status"),
            col("agent_name"),
            col("parent_conversation_id"),
            col("nesting_depth"),
            col("not_fully_idle"),
            col("killed"),
        );
        let mut stmt = conn.prepare(&sql).ok()?;
        let rows = stmt
            .query_map([], |row| {
                let text = |i: usize| -> Option<String> {
                    row.get::<_, Option<String>>(i)
                        .ok()
                        .flatten()
                        .or_else(|| row.get::<_, Option<i64>>(i).ok().flatten().map(|v| v.to_string()))
                };
                let int = |i: usize| -> i64 {
                    row.get::<_, Option<i64>>(i)
                        .ok()
                        .flatten()
                        .or_else(|| text(i).and_then(|t| t.trim().parse().ok()))
                        .unwrap_or(0)
                };
                let status = text(7).unwrap_or_default();
                Ok(Raw {
                    id: row.get(0)?,
                    title: text(1).as_deref().and_then(flattened),
                    preview: text(2),
                    step_count: int(3),
                    last_modified_ms: text(4).as_deref().and_then(parse_timestamp_ms),
                    last_user_input_ms: text(5).as_deref().and_then(parse_timestamp_ms),
                    workspace_path: text(6).as_deref().and_then(parse_first_workspace_uri),
                    active_status: matches!(
                        status.trim(),
                        "CASCADE_RUN_STATUS_RUNNING" | "CASCADE_RUN_STATUS_BUSY" | "CASCADE_RUN_STATUS_CANCELING"
                    ),
                    agent_name: text(8).as_deref().and_then(flattened),
                    parent_id: text(9).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
                    nesting_depth: int(10),
                    not_fully_idle: int(11) != 0,
                    killed: int(12) != 0,
                })
            })
            .ok()?;
        let raws: BTreeMap<String, Raw> = rows.flatten().map(|r| (r.id.clone(), r)).collect();

        let mut fg_subagents = HashSet::new();
        let mut bg_subagents = HashSet::new();
        let mut activities: HashMap<String, Vec<String>> = HashMap::new();
        let mut sub_started: HashMap<String, i64> = HashMap::new();
        for row in raws.values().filter(|r| r.parent_id.is_some() && !r.killed) {
            if !(row.active_status || row.not_fully_idle) {
                continue;
            }
            let mut current = row.id.clone();
            let mut hops = 0;
            while let Some(parent) = raws.get(&current).and_then(|r| r.parent_id.clone()) {
                if hops >= 16 {
                    break;
                }
                current = parent;
                hops += 1;
            }
            if current == row.id {
                continue;
            }
            if row.active_status {
                fg_subagents.insert(current.clone());
            } else {
                bg_subagents.insert(current.clone());
            }
            if let Some(started) = row.last_user_input_ms.or(row.last_modified_ms) {
                let entry = sub_started.entry(current.clone()).or_insert(started);
                *entry = (*entry).min(started);
            }
            if let Some(label) = row.agent_name.clone().or_else(|| row.title.clone()) {
                let text = format!("Subagent · {label}");
                let list = activities.entry(current.clone()).or_default();
                if !list.contains(&text) {
                    list.push(text);
                }
            }
        }

        let annotations = root.join("annotations");
        let mut sessions = HashMap::new();
        for row in raws.values() {
            if row.parent_id.is_some()
                || row.nesting_depth != 0
                || !(row.step_count > 0 || row.active_status || row.not_fully_idle)
            {
                continue;
            }
            let pbtxt = annotations.join(format!("{}.pbtxt", row.id));
            let (annotation, annotation_stamp) = self.read_pbtxt_cached(&pbtxt);
            sessions.insert(
                row.id.clone(),
                AgySession {
                    id: row.id.clone(),
                    title: annotation.as_ref().and_then(|a| a.title.clone()).or_else(|| row.title.clone()),
                    preview: row.preview.clone(),
                    workspace_path: row.workspace_path.clone(),
                    last_modified_ms: row.last_modified_ms,
                    last_modified_s: row.last_modified_ms.map_or(0, |m| m.div_euclid(1000)),
                    last_user_input_ms: row.last_user_input_ms,
                    last_user_view_ms: annotation.as_ref().and_then(|a| a.last_user_view_ms),
                    last_user_view_s: annotation.as_ref().and_then(|a| a.last_user_view_s),
                    annotation_modified_ms: annotation_stamp.map(|s| s.modified_ms),
                    has_annotation: annotation.is_some(),
                    marked_as_unread: annotation.as_ref().is_some_and(|a| a.marked_as_unread),
                    archived: archived_ids.contains(&row.id) || annotation.as_ref().is_some_and(|a| a.archived),
                    killed: row.killed,
                    active_status: row.active_status,
                    not_fully_idle: row.not_fully_idle,
                    foreground_subagents: fg_subagents.contains(&row.id),
                    background_subagents: bg_subagents.contains(&row.id),
                    subagent_activity: activities.get(&row.id).map(|a| a.join(" · ")),
                    subagent_started_ms: sub_started.get(&row.id).copied(),
                },
            );
        }
        Some(sessions)
    }

    // -- Codex ---------------------------------------------------------------

    fn collect_codex(&mut self, root: &Path, now_ms: i64) -> Option<(Vec<DesktopUnreadTask>, Vec<DesktopRunningTask>)> {
        if !root.is_dir() {
            return None;
        }
        let unread_ids = self.read_codex_unread_ids(root);
        let db_path = newest_codex_state_db(root)?;
        let conn = Connection::open_with_flags(
            &db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .ok()?;
        let _ = conn.busy_timeout(std::time::Duration::from_millis(500));
        let columns = column_names(&conn, "threads");
        if !columns.contains("id") {
            return None;
        }
        let col = |name: &str| if columns.contains(name) { name.to_string() } else { "NULL".to_string() };
        let updated = format!("COALESCE({}, {} * 1000)", col("updated_at_ms"), col("updated_at"));
        let select = format!(
            "SELECT id, {}, {}, {}, {}, {updated} FROM threads \
             WHERE COALESCE(archived, 0) = 0 AND COALESCE(source, '') NOT LIKE '{{\"subagent\"%'",
            col("name"),
            col("title"),
            col("cwd"),
            col("rollout_path"),
        );
        let mut threads: Vec<CodexThread> = Vec::new();
        if let Ok(mut stmt) = conn.prepare(&format!("{select} AND {updated} >= ?1 ORDER BY 6 DESC")) {
            if let Ok(rows) = stmt.query_map([now_ms - CODEX_RECENT_WINDOW_MS], codex_thread_from_row) {
                threads.extend(rows.flatten());
            }
        }
        let known: HashSet<String> = threads.iter().map(|t| t.id.clone()).collect();
        let older: Vec<&String> = unread_ids.iter().filter(|id| !known.contains(*id)).collect();
        if !older.is_empty() {
            let placeholders = vec!["?"; older.len()].join(",");
            if let Ok(mut stmt) = conn.prepare(&format!("{select} AND id IN ({placeholders})")) {
                if let Ok(rows) = stmt.query_map(rusqlite::params_from_iter(older.iter()), codex_thread_from_row) {
                    threads.extend(rows.flatten());
                }
            }
        }

        let mut running = Vec::new();
        let mut unread = Vec::new();
        let mut followed = HashSet::new();
        for thread in threads {
            let rollout = thread.rollout_path.as_deref().map(PathBuf::from);
            let stamp = rollout.as_deref().and_then(file_stamp);
            let workspace_label = thread.cwd.as_deref().and_then(workspace_basename).map(str::to_string);
            let title = session_title(thread.title.as_deref(), None, "Codex 会话");
            if let (Some(path), Some(stamp)) = (&rollout, &stamp) {
                followed.insert(path.clone());
                let state = self.codex_turn_state(path, stamp.len);
                let last_activity = stamp.modified_ms.max(state.last_event_ms.unwrap_or(0));
                if state.running && now_ms - last_activity < QUIET_LIMIT_MS {
                    running.push(DesktopRunningTask {
                        id: thread.id.clone(),
                        platform: "codex".into(),
                        title,
                        workspace_path: thread.cwd.clone(),
                        workspace_label,
                        started_at_ms: state.started_at_ms.unwrap_or(thread.updated_at_ms),
                        current_step: state.activity.clone(),
                        is_background: false,
                    });
                    continue;
                }
            }
            if !unread_ids.contains(&thread.id) {
                continue;
            }
            let preview = match (&rollout, &stamp) {
                (Some(path), Some(stamp)) => self.codex_preview(path, stamp),
                _ => CodexPreview::default(),
            };
            unread.push(DesktopUnreadTask {
                id: thread.id.clone(),
                platform: "codex".into(),
                title,
                workspace_path: thread.cwd.clone(),
                workspace_label,
                completed_at_ms: thread.updated_at_ms,
                turn_duration_ms: preview.duration_ms,
                last_user_prompt: preview.prompt,
                last_reply_preview: preview.reply,
                background_activity: None,
            });
        }
        self.codex_turns.retain(|path, _| followed.contains(path));
        self.codex_previews.retain(|path, _| followed.contains(path));
        Some((unread, running))
    }

    fn read_codex_unread_ids(&mut self, root: &Path) -> HashSet<String> {
        let identity = self.codex_identity(root);
        let path = root.join(".codex-global-state.json");
        let Some(stamp) = file_stamp(&path) else {
            return HashSet::new();
        };
        if let Some((cached_path, cached_stamp, ids)) = &self.codex_unread_cache {
            if cached_path == &path && cached_stamp == &stamp {
                return ids.clone();
            }
        }
        let parsed = fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
        if let Some(json) = &parsed {
            self.codex_activity_ms = codex_activity_times(json);
        }
        let ids = parsed
            .map(|json| codex_unread_ids(&json, identity.as_deref()))
            .unwrap_or_default();
        self.codex_unread_cache = Some((path, stamp, ids.clone()));
        ids
    }

    fn codex_identity(&mut self, root: &Path) -> Option<String> {
        let path = root.join("auth.json");
        let stamp = file_stamp(&path);
        if let Some((cached_path, cached_stamp, identity)) = &self.codex_identity_cache {
            if cached_path == &path && cached_stamp == &stamp {
                return identity.clone();
            }
        }
        let identity = fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|json| codex_identity_key(&json));
        self.codex_identity_cache = Some((path, stamp, identity.clone()));
        identity
    }

    /// Follows `task_started` / `task_complete` / `turn_aborted` and commentary notes
    /// (port of `CodexTurnStateReader`).
    fn codex_turn_state(&mut self, path: &Path, len: u64) -> CodexTurnState {
        if let Some(known) = self.codex_turns.get(path) {
            if known.offset == len {
                return known.state.clone();
            }
            if known.offset < len {
                let next = advance_lines(path, known.offset, len, known.clone(), |progress, line| {
                    if let Some(ts) = line_timestamp_ms(line) {
                        progress.state.last_event_ms = Some(ts);
                    }
                    match codex_turn_event(line) {
                        Some(CodexTurnEvent::Started(at)) => {
                            progress.state = CodexTurnState {
                                running: true,
                                started_at_ms: at,
                                activity: None,
                                last_event_ms: progress.state.last_event_ms,
                            };
                        }
                        Some(CodexTurnEvent::Ended) => {
                            progress.state = CodexTurnState {
                                last_event_ms: progress.state.last_event_ms,
                                ..CodexTurnState::default()
                            };
                        }
                        Some(CodexTurnEvent::Note(text)) => progress.state.activity = Some(text),
                        None => {}
                    }
                });
                self.codex_turns.insert(path.to_path_buf(), next.clone());
                return next.state;
            }
        }
        let mut state = CodexTurnState::default();
        let mut note: Option<String> = None;
        let mut first = true;
        let offset = scan_backward(path, len, |line| {
            if first {
                first = false;
                state.last_event_ms = line_timestamp_ms(line);
            }
            match codex_turn_event(line) {
                Some(CodexTurnEvent::Started(at)) => {
                    state.running = true;
                    state.started_at_ms = at;
                    state.activity = note.take();
                    true
                }
                Some(CodexTurnEvent::Ended) => true,
                Some(CodexTurnEvent::Note(text)) => {
                    note.get_or_insert(text);
                    false
                }
                None => false,
            }
        });
        let progress = CodexTurnProgress { offset, state };
        self.codex_turns.insert(path.to_path_buf(), progress.clone());
        progress.state
    }

    fn codex_preview(&mut self, path: &Path, stamp: &FileStamp) -> CodexPreview {
        if let Some((cached, preview)) = self.codex_previews.get(path) {
            if cached == stamp {
                return preview.clone();
            }
        }
        let mut lines: Vec<String> = Vec::new();
        scan_backward(path, stamp.len, |line| {
            if !line.contains("\"event_msg\"") {
                return false;
            }
            lines.push(line.to_string());
            line.contains("\"task_started\"")
        });
        let mut preview = CodexPreview::default();
        for line in lines.iter().rev() {
            preview.apply(line);
        }
        self.codex_previews.insert(path.to_path_buf(), (stamp.clone(), preview.clone()));
        preview
    }

    // -- caches --------------------------------------------------------------

    fn read_pbtxt_cached(&mut self, path: &Path) -> (Option<PbtxtAnnotation>, Option<FileStamp>) {
        let Some(stamp) = file_stamp(path) else {
            self.pbtxt_cache.remove(path);
            return (None, None);
        };
        if let Some((cached_stamp, cached)) = self.pbtxt_cache.get(path) {
            if cached_stamp == &stamp {
                return (Some(cached.clone()), Some(stamp));
            }
        }
        if stamp.len > 256 * 1024 {
            return (None, None);
        }
        let Ok(text) = fs::read_to_string(path) else {
            return (None, None);
        };
        let parsed = parse_pbtxt_annotation(&text);
        self.pbtxt_cache.insert(path.to_path_buf(), (stamp.clone(), parsed.clone()));
        (Some(parsed), Some(stamp))
    }
}

fn agy_transcript(brain: &Path, id: &str) -> PathBuf {
    brain.join(id).join(".system_generated/logs/transcript.jsonl")
}

// ---------------------------------------------------------------------------
// Antigravity transcript readers
// ---------------------------------------------------------------------------

/// The latest turn of an Antigravity conversation, built from its transcript.
#[derive(Debug, Clone, Default)]
struct AgyTurn {
    prompt: Option<String>,
    prompt_ms: Option<i64>,
    reply: Option<String>,
    user_input: Option<String>,
    activity: Option<String>,
    last_ms: Option<i64>,
    waiting: bool,
}

impl AgyTurn {
    fn duration_ms(&self) -> Option<i64> {
        match (self.prompt_ms, self.last_ms) {
            (Some(start), Some(end)) if end >= start => Some(end - start),
            _ => None,
        }
    }

    fn apply(&mut self, line: &str) {
        let Ok(entry) = serde_json::from_str::<Value>(line) else {
            return;
        };
        let kind = entry.get("type").and_then(Value::as_str).unwrap_or("");
        let source = entry.get("source").and_then(Value::as_str).unwrap_or("");
        let ts = entry.get("created_at").and_then(Value::as_str).and_then(parse_timestamp_ms);
        match (kind, source) {
            ("USER_INPUT", "USER_EXPLICIT") => {
                self.waiting = false;
                if let Some(prompt) = antigravity_human_text(entry.get("content").and_then(Value::as_str)) {
                    *self = AgyTurn {
                        prompt: Some(prompt),
                        prompt_ms: ts,
                        last_ms: ts,
                        ..AgyTurn::default()
                    };
                }
            }
            ("PLANNER_RESPONSE", "MODEL") => {
                if ts.is_some() {
                    self.last_ms = ts;
                }
                let content = entry.get("content").and_then(Value::as_str);
                let summary = reply_summary_opt(content);
                if summary.is_some() {
                    self.reply = summary.clone();
                }
                let calls = entry.get("tool_calls").and_then(Value::as_array).cloned().unwrap_or_default();
                self.waiting = antigravity_pauses_for_user(&calls);
                if let Some(input) = antigravity_user_input(&calls) {
                    self.user_input = Some(input);
                }
                if let Some(tool) = calls.iter().filter_map(antigravity_tool_activity).last() {
                    self.activity = Some(tool);
                } else if summary.is_some() {
                    self.activity = summary;
                }
            }
            _ => {}
        }
    }
}

fn agy_is_prompt(line: &str) -> bool {
    let Ok(entry) = serde_json::from_str::<Value>(line) else {
        return false;
    };
    entry.get("type").and_then(Value::as_str) == Some("USER_INPUT")
        && entry.get("source").and_then(Value::as_str) == Some("USER_EXPLICIT")
        && antigravity_human_text(entry.get("content").and_then(Value::as_str)).is_some()
}

#[derive(Debug, Clone, Default)]
struct AgyTurnProgress {
    offset: u64,
    turn: AgyTurn,
}

impl HasOffset for AgyTurnProgress {
    fn set_offset(&mut self, offset: u64) {
        self.offset = offset;
    }
}

#[derive(Debug, Clone)]
struct AgyBackgroundTask {
    started_ms: i64,
    activity: Option<String>,
    is_timer: bool,
}

/// Port of `AntigravityActivityReader.runningBackgroundTasks`.
#[derive(Debug, Clone, Default)]
struct AgyBackgroundProgress {
    offset: u64,
    pending: HashMap<String, AgyBackgroundTask>,
    last_call_activity: Option<String>,
}

impl HasOffset for AgyBackgroundProgress {
    fn set_offset(&mut self, offset: u64) {
        self.offset = offset;
    }
}

impl AgyBackgroundProgress {
    fn apply(&mut self, line: &str) {
        let relevant = line.contains("\"PLANNER_RESPONSE\"")
            || line.contains("Tool is running as a background task")
            || line.contains("\"SYSTEM_MESSAGE\"")
            || line.contains("\"USER_INPUT\"")
            || line.contains("Task id ");
        if !relevant {
            return;
        }
        for id in finished_task_ids(line) {
            self.pending.remove(&id);
        }
        let Ok(entry) = serde_json::from_str::<Value>(line) else {
            return;
        };
        match entry.get("type").and_then(Value::as_str) {
            Some("SYSTEM_MESSAGE") | Some("USER_INPUT") => {
                // One-shot schedule timers wake the turn or cancel when a watched task reports back.
                self.pending.retain(|_, task| !task.is_timer);
            }
            Some("PLANNER_RESPONSE") if entry.get("source").and_then(Value::as_str) == Some("MODEL") => {
                for call in entry.get("tool_calls").and_then(Value::as_array).into_iter().flatten() {
                    let name = call.get("name").and_then(Value::as_str).unwrap_or("");
                    let args = call_args(call);
                    if name == "manage_task" && arg_string(args, "Action").as_deref() == Some("kill") {
                        if let Some(id) = arg_string(args, "TaskId") {
                            self.pending.remove(&id);
                        }
                    } else if name == "run_command" || name == "schedule" {
                        if let Some(activity) = antigravity_tool_activity(call) {
                            self.last_call_activity = Some(activity);
                        }
                    }
                }
            }
            Some("GENERIC") if entry.get("status").and_then(Value::as_str) == Some("RUNNING") => {
                let Some(content) = entry.get("content").and_then(Value::as_str) else {
                    return;
                };
                const MARKER: &str = "Tool is running as a background task with task id:";
                let Some(at) = content.find(MARKER) else {
                    return;
                };
                let Some(id) = content[at + MARKER.len()..].split_whitespace().next() else {
                    return;
                };
                let Some(started) = entry.get("created_at").and_then(Value::as_str).and_then(parse_timestamp_ms) else {
                    return;
                };
                let desc = content
                    .find("Task Description:")
                    .and_then(|i| content[i + "Task Description:".len()..].lines().next())
                    .and_then(flattened);
                let is_timer = desc.as_deref().is_some_and(|d| d.starts_with("Timer:"));
                let fallback = desc.map(|d| format!("Run {d}"));
                self.pending.insert(
                    id.to_string(),
                    AgyBackgroundTask {
                        started_ms: started,
                        activity: self.last_call_activity.take().or(fallback),
                        is_timer,
                    },
                );
            }
            _ => {}
        }
    }
}

/// Task ids reported as finished or canceled, and message senders.
fn finished_task_ids(line: &str) -> Vec<String> {
    let mut ids = Vec::new();
    let mut rest = line;
    while let Some(i) = rest.find("Task id ") {
        rest = &rest[i + "Task id ".len()..];
        let body = rest.trim_start_matches('\\').trim_start_matches('"');
        let end = body.find(['"', '\\']).unwrap_or(body.len());
        let id = &body[..end];
        let after = body[end..].trim_start_matches('\\').trim_start_matches('"');
        if !id.is_empty() && (after.starts_with(" finished") || after.starts_with(" was canceled")) {
            ids.push(id.to_string());
        }
    }
    let mut rest = line;
    while let Some(i) = rest.find("sender=") {
        rest = &rest[i + "sender=".len()..];
        let end = rest
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '/' || c == '_'))
            .unwrap_or(rest.len());
        if end >= 8 {
            ids.push(rest[..end].to_string());
        }
    }
    ids
}

fn call_args(call: &Value) -> Option<&Value> {
    call.get("args").or_else(|| call.get("arguments"))
}

/// Antigravity encodes tool arguments as JSON text; decodes them when they are.
fn arg_value(value: &Value) -> Value {
    if let Some(text) = value.as_str() {
        let trimmed = text.trim();
        if trimmed.starts_with('"')
            || trimmed.starts_with('{')
            || trimmed.starts_with('[')
            || trimmed == "true"
            || trimmed == "false"
        {
            if let Ok(decoded) = serde_json::from_str::<Value>(trimmed) {
                return decoded;
            }
        }
    }
    value.clone()
}

fn arg_string(args: Option<&Value>, key: &str) -> Option<String> {
    arg_value(args?.get(key)?).as_str().map(str::to_string)
}

fn arg_bool(value: Option<&Value>) -> bool {
    match value.map(arg_value) {
        Some(Value::Bool(b)) => b,
        Some(Value::String(s)) => s == "true",
        _ => false,
    }
}

/// Port of `antigravityToolActivity`.
fn antigravity_tool_activity(call: &Value) -> Option<String> {
    let name = call.get("name").and_then(Value::as_str).filter(|n| !n.is_empty())?;
    let args = call_args(call);
    for key in ["toolSummary", "toolAction", "Description"] {
        if let Some(summary) = arg_string(args, key).as_deref().and_then(flattened) {
            return Some(summary);
        }
    }
    if name == "invoke_subagent" {
        if let Some(role) = arg_string(args, "Role").as_deref().and_then(flattened) {
            return Some(format!("Subagent · {role}"));
        }
    }
    if name == "schedule" {
        if let Some(prompt) = arg_string(args, "Prompt").as_deref().and_then(flattened) {
            return Some(format!("Schedule · {prompt}"));
        }
    }
    let path = ["Path", "TargetFile", "AbsolutePath", "DirectoryPath", "SearchPath"]
        .iter()
        .find_map(|k| arg_string(args, k).filter(|p| !p.is_empty()));
    if let Some(path) = path {
        let file = workspace_basename(&path).unwrap_or(&path).to_string();
        return Some(match name {
            "read_file" | "view_file" | "view_file_outline" | "view_code_item" => format!("Read {file}"),
            "edit_file" | "replace_file_content" | "multi_replace_file_content" => format!("Edit {file}"),
            "write_file" | "write_to_file" => format!("Write {file}"),
            "list_dir" => format!("List {file}"),
            "grep_search" | "find_by_name" => {
                match arg_string(args, "Query").or_else(|| arg_string(args, "Pattern")).as_deref().and_then(flattened) {
                    Some(query) => format!("Search {query} in {file}"),
                    None => format!("Search {file}"),
                }
            }
            other => format!("{other} {file}"),
        });
    }
    for (key, verb) in [
        ("CommandLine", "Run"),
        ("Query", "Search"),
        ("query", "Search"),
        ("Pattern", "Find"),
        ("Url", "Read"),
        ("url", "Read"),
    ] {
        if let Some(line) = arg_string(args, key).and_then(|v| v.lines().next().and_then(flattened)) {
            return Some(format!("{verb} {line}"));
        }
    }
    None
}

/// Port of `antigravityPausesForUser`.
fn antigravity_pauses_for_user(calls: &[Value]) -> bool {
    calls.iter().any(|call| {
        if call.get("name").and_then(Value::as_str) == Some("ask_question") {
            return true;
        }
        let metadata = call_args(call).and_then(|a| a.get("ArtifactMetadata")).map(arg_value);
        arg_bool(metadata.as_ref().and_then(|m| m.get("RequestFeedback")))
    })
}

/// Port of `antigravityUserInput`.
fn antigravity_user_input(calls: &[Value]) -> Option<String> {
    let mut texts = Vec::new();
    for call in calls {
        let name = call.get("name").and_then(Value::as_str).unwrap_or("");
        let args = call_args(call);
        let metadata = args.and_then(|a| a.get("ArtifactMetadata")).map(arg_value);
        if name == "ask_question" {
            let questions: Vec<String> = args
                .and_then(|a| a.get("questions"))
                .map(arg_value)
                .and_then(|q| q.as_array().cloned())
                .unwrap_or_default()
                .iter()
                .filter_map(|q| q.get("question").map(arg_value).and_then(|v| v.as_str().map(str::to_string)))
                .collect();
            texts.push(if questions.is_empty() { "等待你的回答".to_string() } else { questions.join(" ") });
        } else if arg_bool(metadata.as_ref().and_then(|m| m.get("RequestFeedback"))) {
            let summary = metadata
                .as_ref()
                .and_then(|m| m.get("Summary"))
                .map(arg_value)
                .and_then(|v| v.as_str().map(str::to_string))
                .and_then(|s| reply_summary(&s));
            if let Some(summary) = summary {
                texts.push(summary);
            } else if let Some(path) = arg_string(args, "Path").or_else(|| arg_string(args, "TargetFile")) {
                texts.push(format!("Review {}", workspace_basename(&path).unwrap_or(&path)));
            } else {
                texts.push("等待你确认".to_string());
            }
        } else if name == "notify_user" {
            if let Some(message) = arg_string(args, "Message").and_then(|m| reply_summary(&m)) {
                texts.push(message);
            }
        }
    }
    (!texts.is_empty()).then(|| texts.join(" · ")).as_deref().and_then(flattened)
}

/// Port of `antigravityHumanText`.
fn antigravity_human_text(text: Option<&str>) -> Option<String> {
    let text = text?;
    let body = if let Some(start) = text.find("<USER_REQUEST>") {
        let after = &text[start + "<USER_REQUEST>".len()..];
        after.find("</USER_REQUEST>").map_or(after, |end| &after[..end])
    } else if text.trim_start().starts_with('<') {
        return None;
    } else {
        text
    };
    flattened(body.trim())
}

// ---------------------------------------------------------------------------
// Codex rollout readers
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
struct CodexTurnState {
    running: bool,
    started_at_ms: Option<i64>,
    activity: Option<String>,
    last_event_ms: Option<i64>,
}

#[derive(Debug, Clone, Default)]
struct CodexTurnProgress {
    offset: u64,
    state: CodexTurnState,
}

impl HasOffset for CodexTurnProgress {
    fn set_offset(&mut self, offset: u64) {
        self.offset = offset;
    }
}

enum CodexTurnEvent {
    Started(Option<i64>),
    Ended,
    Note(String),
}

fn codex_turn_event(line: &str) -> Option<CodexTurnEvent> {
    const MARKERS: [&str; 4] = ["\"task_started\"", "\"task_complete\"", "\"turn_aborted\"", "\"commentary\""];
    if !MARKERS.iter().any(|m| line.contains(m)) {
        return None;
    }
    let entry: Value = serde_json::from_str(line).ok()?;
    if entry.get("type").and_then(Value::as_str) != Some("event_msg") {
        return None;
    }
    let payload = entry.get("payload")?;
    match payload.get("type").and_then(Value::as_str)? {
        "task_started" => Some(CodexTurnEvent::Started(
            entry.get("timestamp").and_then(Value::as_str).and_then(parse_timestamp_ms),
        )),
        "task_complete" | "turn_aborted" => Some(CodexTurnEvent::Ended),
        "item_completed" => {
            // Codex marks the messages it writes while working as commentary.
            let item = payload.get("item")?;
            if item.get("type").and_then(Value::as_str) != Some("AgentMessage")
                || item.get("phase").and_then(Value::as_str) != Some("commentary")
            {
                return None;
            }
            reply_summary_opt(codex_text_blocks(item.get("content")).as_deref()).map(CodexTurnEvent::Note)
        }
        _ => None,
    }
}

/// Codex labels text blocks `Text` in its own items and `text` in model messages.
fn codex_text_blocks(content: Option<&Value>) -> Option<String> {
    let texts: Vec<&str> = content?
        .as_array()?
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str).is_some_and(|t| t.eq_ignore_ascii_case("text")))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect();
    (!texts.is_empty()).then(|| texts.join("\n"))
}

/// Prompt, reply and duration of the latest Codex turn.
#[derive(Debug, Clone, Default)]
struct CodexPreview {
    prompt: Option<String>,
    reply: Option<String>,
    duration_ms: Option<i64>,
    started_ms: Option<i64>,
}

impl CodexPreview {
    fn apply(&mut self, line: &str) {
        let Ok(entry) = serde_json::from_str::<Value>(line) else {
            return;
        };
        if entry.get("type").and_then(Value::as_str) != Some("event_msg") {
            return;
        }
        let Some(payload) = entry.get("payload") else {
            return;
        };
        let ts = entry.get("timestamp").and_then(Value::as_str).and_then(parse_timestamp_ms);
        match payload.get("type").and_then(Value::as_str).unwrap_or("") {
            "task_started" => {
                *self = CodexPreview { started_ms: ts, ..CodexPreview::default() };
            }
            "user_message" => {
                if let Some(prompt) = codex_human_text(payload.get("message").and_then(Value::as_str)) {
                    self.prompt = Some(prompt);
                }
            }
            "agent_message" => {
                if let Some(reply) = reply_summary_opt(payload.get("message").and_then(Value::as_str)) {
                    self.reply = Some(reply);
                }
            }
            "task_complete" => {
                if let Some(reply) = reply_summary_opt(payload.get("last_agent_message").and_then(Value::as_str)) {
                    self.reply = Some(reply);
                }
                self.duration_ms = payload
                    .get("duration_ms")
                    .and_then(Value::as_i64)
                    .or_else(|| match (self.started_ms, ts) {
                        (Some(s), Some(e)) if e >= s => Some(e - s),
                        _ => None,
                    });
            }
            _ => {}
        }
    }
}

/// Port of `codexHumanText`: Codex wraps attachments around the request and
/// sends replies to its own questions as XML.
fn codex_human_text(text: Option<&str>) -> Option<String> {
    let mut text = text?;
    if let Some(i) = text.find("## My request:") {
        text = &text[i + "## My request:".len()..];
    }
    let trimmed = text.trim();
    if trimmed.starts_with('<') || trimmed.starts_with('#') {
        return None;
    }
    flattened(trimmed)
}

/// Extracts per-thread user activity timestamps (`["local","<id>"]` -> epoch ms)
/// from `electron-persisted-atom-state.thread-user-activity-times-v1`.
fn codex_activity_times(json: &Value) -> HashMap<String, i64> {
    let mut times = HashMap::new();
    let Some(map) = json
        .get("electron-persisted-atom-state")
        .and_then(|v| v.get("thread-user-activity-times-v1"))
        .and_then(Value::as_object)
    else {
        return times;
    };
    for (raw_key, val) in map {
        let Some(at_ms) = val.as_i64() else {
            continue;
        };
        if let Ok(pair) = serde_json::from_str::<Vec<String>>(raw_key) {
            if pair.len() == 2 && pair[0].starts_with("local") {
                times.insert(pair[1].clone(), at_ms);
            }
        }
    }
    times
}

/// Thread IDs Codex Desktop lists as unread for local hosts. With a known
/// identity only that identity's list counts, as on macOS.
fn codex_unread_ids(json: &Value, identity: Option<&str>) -> HashSet<String> {
    let mut ids = HashSet::new();
    let Some(identities) = json
        .get("electron-thread-read-state-v1")
        .and_then(|v| v.get("unreadByIdentity"))
        .and_then(Value::as_object)
    else {
        return ids;
    };
    let hosts: Vec<&Value> = match identity {
        Some(key) => identities.get(key).into_iter().collect(),
        None => identities.values().collect(),
    };
    for hosts in hosts.into_iter().filter_map(Value::as_object) {
        for (host, list) in hosts {
            if !host.starts_with("local:") {
                continue;
            }
            for id in list.as_array().into_iter().flatten().filter_map(Value::as_str) {
                ids.insert(id.to_string());
            }
        }
    }
    ids
}

/// Codex Desktop keys ChatGPT sign-ins by
/// `sha256(JSON.stringify(["chatgpt", accountId, userId]))`.
fn codex_identity_key(auth: &Value) -> Option<String> {
    let tokens = auth.get("tokens")?;
    let id_token = tokens.get("id_token")?.as_str()?;
    let payload = id_token.split('.').nth(1)?;
    let claims: Value = serde_json::from_slice(&base64url_decode(payload)?).ok()?;
    let auth_claims = claims.get("https://api.openai.com/auth");
    let account = tokens
        .get("account_id")
        .and_then(Value::as_str)
        .or_else(|| auth_claims?.get("chatgpt_account_id")?.as_str())?;
    let user = auth_claims
        .and_then(|a| a.get("chatgpt_user_id").or_else(|| a.get("user_id")))
        .and_then(Value::as_str)?;
    let identity = serde_json::to_string(&["chatgpt", account, user]).ok()?;
    Some(sha256_hex(identity.as_bytes()))
}

fn base64url_decode(input: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len() * 3 / 4);
    let mut buffer = 0u32;
    let mut bits = 0;
    for c in input.bytes() {
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            b'=' => break,
            _ => return None,
        } as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(out)
}

fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    let mut message = data.to_vec();
    let bit_len = (data.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_be_bytes());
    for chunk in message.chunks(64) {
        let mut w = [0u32; 64];
        for (i, word) in chunk.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (slot, value) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *slot = slot.wrapping_add(value);
        }
    }
    h.iter().map(|v| format!("{v:08x}")).collect()
}

fn codex_thread_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CodexThread> {
    let name: Option<String> = row.get(1).ok().flatten();
    let first_prompt: Option<String> = row.get(2).ok().flatten();
    Ok(CodexThread {
        id: row.get(0)?,
        title: name
            .as_deref()
            .and_then(flattened)
            .or_else(|| first_prompt.as_deref().and_then(flattened)),
        cwd: row.get::<_, Option<String>>(3).ok().flatten().filter(|s| !s.trim().is_empty()),
        rollout_path: row.get(4).ok().flatten(),
        updated_at_ms: row.get::<_, Option<i64>>(5).ok().flatten().unwrap_or(0),
    })
}

fn newest_codex_state_db(root: &Path) -> Option<PathBuf> {
    fs::read_dir(root)
        .ok()?
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let version = path
                .file_name()?
                .to_str()?
                .strip_prefix("state_")?
                .strip_suffix(".sqlite")?
                .parse::<u64>()
                .ok()?;
            Some((version, path))
        })
        .max_by_key(|(version, _)| *version)
        .map(|(_, path)| path)
}

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

trait HasOffset {
    fn set_offset(&mut self, offset: u64);
}

/// Applies the complete lines appended after `offset`. A line still being
/// written is read again once it ends.
fn advance_lines<T: HasOffset>(path: &Path, offset: u64, len: u64, known: T, mut apply: impl FnMut(&mut T, &str)) -> T {
    let mut next = known;
    let Ok(mut file) = File::open(path) else {
        return next;
    };
    let mut appended = vec![0u8; (len - offset) as usize];
    if file.seek(SeekFrom::Start(offset)).is_err() || file.read_exact(&mut appended).is_err() {
        return next;
    }
    let Some(last_newline) = appended.iter().rposition(|&b| b == b'\n') else {
        return next;
    };
    for raw in appended[..last_newline].split(|&b| b == b'\n') {
        if let Ok(line) = std::str::from_utf8(raw) {
            let line = line.trim();
            if !line.is_empty() {
                apply(&mut next, line);
            }
        }
    }
    next.set_offset(offset + last_newline as u64 + 1);
    next
}

/// Visits complete lines from the end of the file backward until `visit`
/// returns true or `MAX_SCAN_BYTES` were read. Returns the offset just past
/// the last complete line, for later incremental reads.
fn scan_backward(path: &Path, len: u64, mut visit: impl FnMut(&str) -> bool) -> u64 {
    let Ok(mut file) = File::open(path) else {
        return len;
    };
    const CHUNK: u64 = 256 * 1024;
    let floor = len.saturating_sub(MAX_SCAN_BYTES);
    let mut end = len;
    let mut carry: Vec<u8> = Vec::new();
    let mut offset = len;
    let mut first_chunk = true;
    while end > floor {
        let start = end.saturating_sub(CHUNK).max(floor);
        let mut chunk = vec![0u8; (end - start) as usize];
        if file.seek(SeekFrom::Start(start)).is_err() || file.read_exact(&mut chunk).is_err() {
            break;
        }
        chunk.extend_from_slice(&carry);
        // The first segment may continue in the previous chunk; keep it for later.
        let split = if start > floor {
            chunk.iter().position(|&b| b == b'\n').map_or(chunk.len(), |p| p + 1)
        } else {
            0
        };
        carry = chunk[..split].to_vec();
        let mut lines: Vec<&[u8]> = chunk[split..].split(|&b| b == b'\n').collect();
        if first_chunk {
            first_chunk = false;
            let tail = lines.pop().unwrap_or(&[]);
            offset = len - tail.len() as u64;
        }
        for raw in lines.iter().rev() {
            let Ok(line) = std::str::from_utf8(raw) else { continue };
            let line = line.trim();
            if !line.is_empty() && visit(line) {
                return offset;
            }
        }
        end = start;
    }
    offset
}

fn line_timestamp_ms(line: &str) -> Option<i64> {
    let entry: Value = serde_json::from_str(line).ok()?;
    entry
        .get("timestamp")
        .and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(parse_timestamp_ms)))
}

fn column_names(conn: &Connection, table: &str) -> HashSet<String> {
    let mut names = HashSet::new();
    if let Ok(mut stmt) = conn.prepare(&format!("PRAGMA table_info({table})")) {
        if let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(1)) {
            names.extend(rows.flatten());
        }
    }
    names
}

fn file_stamp(path: &Path) -> Option<FileStamp> {
    let meta = fs::metadata(path).ok()?;
    let modified_ms = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Some(FileStamp {
        modified_ms,
        len: meta.len(),
    })
}

/// Parses Antigravity SQLite dates (`2026-11-06 15:00:00.123`, UTC), RFC 3339 and epoch numbers.
fn parse_timestamp_ms(value: &str) -> Option<i64> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(num) = trimmed.parse::<i64>() {
        return Some(if num > 10_000_000_000 { num } else { num * 1000 });
    }
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(trimmed) {
        return Some(dt.timestamp_millis());
    }
    let normalized = trimmed.replacen(' ', "T", 1);
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(&normalized) {
        return Some(dt.timestamp_millis());
    }
    for format in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S"] {
        if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(&normalized, format) {
            return Some(naive.and_utc().timestamp_millis());
        }
    }
    None
}

fn parse_pbtxt_annotation(text: &str) -> PbtxtAnnotation {
    let mut result = PbtxtAnnotation::default();
    for raw in text.lines() {
        let line = raw.trim();
        if line.starts_with("title:") && result.title.is_none() {
            result.title = extract_pbtxt_string(line).as_deref().and_then(flattened);
        } else if line.starts_with("marked_as_unread:") {
            result.marked_as_unread = line.ends_with("true");
        } else if line.starts_with("archived:") {
            result.archived = line.ends_with("true");
        }
    }
    // `last_user_view_time { seconds: 1 nanos: 2 }`, on one line or several.
    let block = text
        .find("last_user_view_time")
        .and_then(|start| {
            let rest = &text[start..];
            let open = rest.find('{')?;
            let close = rest[open..].find('}')?;
            Some(&rest[open + 1..open + close])
        })
        .unwrap_or("");
    let tokens: Vec<&str> = block
        .split(|c: char| c.is_whitespace() || c == ':')
        .filter(|t| !t.is_empty())
        .collect();
    let value = |key: &str| {
        tokens
            .windows(2)
            .find(|w| w[0] == key)
            .and_then(|w| w[1].parse::<i64>().ok())
    };
    if let Some(seconds) = value("seconds") {
        let nanos = value("nanos").unwrap_or(0);
        result.last_user_view_s = Some(seconds);
        result.last_user_view_ms = Some(seconds * 1000 + nanos / 1_000_000);
    }
    result
}

fn extract_pbtxt_string(line: &str) -> Option<String> {
    let start = line.find('"')?;
    let end = line.rfind('"')?;
    if end <= start {
        return None;
    }
    let raw = &line[start + 1..end];
    let mut bytes = Vec::with_capacity(raw.len());
    let mut chars = raw.bytes().peekable();
    while let Some(b) = chars.next() {
        if b != b'\\' {
            bytes.push(b);
            continue;
        }
        match chars.next() {
            Some(b'n') => bytes.push(b'\n'),
            Some(b'r') => bytes.push(b'\r'),
            Some(b't') => bytes.push(b'\t'),
            Some(d @ b'0'..=b'7') => {
                let mut value = (d - b'0') as u32;
                for _ in 0..2 {
                    match chars.peek() {
                        Some(&n @ b'0'..=b'7') => {
                            value = value * 8 + (n - b'0') as u32;
                            chars.next();
                        }
                        _ => break,
                    }
                }
                bytes.push(value as u8);
            }
            Some(other) => bytes.push(other),
            None => break,
        }
    }
    String::from_utf8(bytes).ok()
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

fn reply_summary_opt(markdown: Option<&str>) -> Option<String> {
    markdown.and_then(reply_summary)
}

/// Port of `replySummary`: reduces Markdown to its opening text, dropping code
/// blocks, table rules, and heading, list, quote, emphasis and link markup.
fn reply_summary(markdown: &str) -> Option<String> {
    let mut lines: Vec<String> = Vec::new();
    let mut length = 0;
    let mut in_code = false;
    for raw in markdown.split('\n') {
        let mut line = raw.trim().to_string();
        if line.starts_with("```") || line.starts_with("~~~") {
            in_code = !in_code;
            continue;
        }
        if in_code || line.is_empty() || line.chars().all(|c| "|-:+ ".contains(c)) {
            continue;
        }
        while line.starts_with('#') || line.starts_with('>') {
            line = line[1..].trim().to_string();
        }
        line = strip_list_marker(&line).to_string();
        line = line.replace('|', " ");
        length += line.chars().count();
        lines.push(line);
        if length > MAX_TEXT_CHARS {
            break;
        }
    }
    let mut text = strip_links(&lines.join(" "));
    for markup in ["**", "__", "`"] {
        text = text.replace(markup, "");
    }
    flattened(&text)
}

fn strip_list_marker(line: &str) -> &str {
    let bytes = line.as_bytes();
    if bytes.len() >= 2 && matches!(bytes[0], b'-' | b'*' | b'+') && bytes[1].is_ascii_whitespace() {
        return line[1..].trim_start();
    }
    let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
    if digits > 0
        && bytes.len() > digits + 1
        && matches!(bytes[digits], b'.' | b')')
        && bytes[digits + 1].is_ascii_whitespace()
    {
        return line[digits + 1..].trim_start();
    }
    line
}

/// `[text](url)` → `text`.
fn strip_links(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        let Some(close) = rest[open..].find("](").map(|i| open + i) else {
            break;
        };
        let Some(end) = rest[close + 2..].find(')').map(|i| close + 2 + i) else {
            break;
        };
        if rest[open + 1..close].contains('[') {
            out.push_str(&rest[..open + 1]);
            rest = &rest[open + 1..];
            continue;
        }
        out.push_str(&rest[..open]);
        out.push_str(&rest[open + 1..close]);
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    out
}

/// Collapses whitespace into one line and limits its length.
fn flattened(raw: &str) -> Option<String> {
    let joined = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if joined.is_empty() {
        return None;
    }
    Some(truncate_chars(&joined, MAX_TEXT_CHARS))
}

fn session_title(title: Option<&str>, fallback_text: Option<&str>, fallback: &str) -> String {
    title
        .and_then(flattened)
        .or_else(|| fallback_text.and_then(flattened))
        .map(|t| truncate_chars(&t, 80))
        .unwrap_or_else(|| fallback.to_string())
}

fn truncate_chars(text: &str, max_chars: usize) -> String {
    let mut chars = text.chars();
    let prefix: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{}…", prefix.chars().take(max_chars.saturating_sub(1)).collect::<String>())
    } else {
        prefix
    }
}

fn parse_first_workspace_uri(raw: &str) -> Option<String> {
    let first = serde_json::from_str::<Vec<String>>(raw.trim())
        .ok()
        .and_then(|v| v.into_iter().next())?;
    let first = first.trim();
    if first.is_empty() {
        return None;
    }
    let stripped = first
        .strip_prefix("file:///")
        .or_else(|| first.strip_prefix("file://"))
        .unwrap_or(first);
    let decoded = percent_decode(stripped);
    let path = if cfg!(windows) { decoded.replace('/', "\\") } else { decoded };
    (!path.is_empty()).then_some(path)
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(value) = u8::from_str_radix(&input[i + 1..i + 3], 16) {
                out.push(value);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn workspace_basename(path: &str) -> Option<&str> {
    path.trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .find(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(id: &str, modified_s: i64, view_s: Option<i64>) -> AgySession {
        AgySession {
            id: id.into(),
            last_modified_ms: Some(modified_s * 1000),
            last_modified_s: modified_s,
            last_user_view_ms: view_s.map(|s| s * 1000),
            last_user_view_s: view_s,
            has_annotation: view_s.is_some(),
            ..AgySession::default()
        }
    }

    fn unread(platform: &str, id: &str, completed: i64) -> DesktopUnreadTask {
        DesktopUnreadTask {
            id: id.into(),
            platform: platform.into(),
            title: id.into(),
            workspace_path: None,
            workspace_label: None,
            completed_at_ms: completed,
            turn_duration_ms: None,
            last_user_prompt: None,
            last_reply_preview: None,
            background_activity: None,
        }
    }

    #[test]
    fn parses_antigravity_sqlite_dates_as_utc() {
        assert_eq!(parse_timestamp_ms("2026-11-06 15:00:00"), Some(1_793_977_200_000));
        assert_eq!(parse_timestamp_ms("2026-11-06 15:00:00.250"), Some(1_793_977_200_250));
    }

    #[test]
    fn parses_pbtxt_view_time() {
        let parsed = parse_pbtxt_annotation(
            "title: \"\\344\\277\\256\\345\\244\\215\"\nlast_user_view_time {\n  seconds: 1700000010\n  nanos: 500000000\n}\nmarked_as_unread: true\n",
        );
        assert_eq!(parsed.title.as_deref(), Some("修复"));
        assert_eq!(parsed.last_user_view_ms, Some(1_700_000_010_500));
        assert!(parsed.marked_as_unread);
    }

    #[test]
    fn codex_identity_matches_codex_desktop_key() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let json: Value = serde_json::json!({
            "electron-thread-read-state-v1": {"unreadByIdentity": {
                "me": {"local:h": ["t1"], "remote-control:x": ["r1"]},
                "other": {"local:h": ["t2"]}
            }}
        });
        let mine = codex_unread_ids(&json, Some("me"));
        assert!(mine.contains("t1") && !mine.contains("t2") && !mine.contains("r1"));
    }

    #[test]
    fn follows_codex_turn_across_appends() {
        use std::io::Write;
        let path = std::env::temp_dir().join(format!("tokenbar-codex-turn-{}.jsonl", std::process::id()));
        let started = r#"{"timestamp":"2026-11-06T16:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#;
        let note = r#"{"timestamp":"2026-11-06T16:00:05.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","content":[{"type":"Text","text":"正在检查构建"}]}}}"#;
        fs::write(&path, format!("{started}\n{note}\n")).unwrap();
        let mut monitor = DesktopTaskMonitor::new(None);
        let state = monitor.codex_turn_state(&path, fs::metadata(&path).unwrap().len());
        assert!(state.running);
        assert_eq!(state.activity.as_deref(), Some("正在检查构建"));
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(file, r#"{{"timestamp":"2026-11-06T16:01:00.000Z","type":"event_msg","payload":{{"type":"task_complete"}}}}"#).unwrap();
        drop(file);
        assert!(!monitor.codex_turn_state(&path, fs::metadata(&path).unwrap().len()).running);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn antigravity_turn_unread_until_viewed() {
        let mut tracker = AgyTracker::restore(None);
        let none = HashSet::new();
        let mut sessions = HashMap::from([("a".to_string(), session("a", 1_000, Some(1_010)))]);
        assert!(tracker.update(&sessions, &none, &none, false, 1_020_000).is_empty());
        sessions.insert("a".into(), session("a", 1_100, Some(1_010)));
        assert!(tracker.update(&sessions, &none, &none, false, 1_110_000).contains("a"));
        tracker.mark_viewed("a", 1_120_000, 1_120_000, true);
        assert!(tracker.update(&sessions, &none, &none, false, 1_121_000).is_empty());
    }

    #[test]
    fn antigravity_turn_watched_in_front_is_read() {
        let mut tracker = AgyTracker::restore(None);
        let none = HashSet::new();
        let working = HashSet::from(["a".to_string()]);
        let mut sessions = HashMap::from([("a".to_string(), session("a", 1_000, Some(1_010)))]);
        tracker.update(&sessions, &working, &none, true, 1_020_000);
        sessions.insert("a".into(), session("a", 1_100, Some(1_010)));
        assert!(tracker.update(&sessions, &none, &none, true, 1_110_000).is_empty());
    }

    #[test]
    fn notify_user_ends_turn_without_waiting() {
        let notify = serde_json::json!([{"name": "notify_user", "args": {"Message": "\"做完了\""}}]);
        assert!(!antigravity_pauses_for_user(notify.as_array().unwrap()));
        let review = serde_json::json!([{"name": "write_file", "args": {"ArtifactMetadata": "{\"RequestFeedback\": true}"}}]);
        assert!(antigravity_pauses_for_user(review.as_array().unwrap()));
    }

    #[test]
    fn brief_codex_visit_keeps_task_unread_until_dwell() {
        let mut monitor = DesktopTaskMonitor::new(None);
        monitor.accept("codex", vec![unread("codex", "t", 1_000)], None, 2_000);
        // Codex clears its unread mark after a one-second pass through the app.
        monitor.record_foreground(Some("codex"), 3_000);
        monitor.record_foreground(None, 4_000);
        monitor.accept("codex", vec![], None, 4_500);
        assert_eq!(monitor.publish("codex", 4_500).len(), 1);
        // A later visit of three seconds reads it.
        monitor.record_foreground(Some("codex"), 10_000);
        monitor.accept("codex", vec![], None, 13_500);
        assert!(monitor.publish("codex", 13_500).is_empty());
    }

    #[test]
    fn opened_task_hidden_until_newer_turn() {
        let mut monitor = DesktopTaskMonitor::new(None);
        monitor.accept("codex", vec![unread("codex", "t", 1_000)], None, 2_000);
        monitor.mark_opened("codex", "t", 5_000);
        assert!(monitor.publish("codex", 6_000).is_empty());
        monitor.accept("codex", vec![unread("codex", "t", 9_000)], None, 9_500);
        assert_eq!(monitor.publish("codex", 9_500).len(), 1);
    }

    #[test]
    fn background_task_tracked_until_finished() {
        let mut progress = AgyBackgroundProgress::default();
        progress.apply(r#"{"type":"PLANNER_RESPONSE","source":"MODEL","tool_calls":[{"name":"run_command","args":{"toolSummary":"\"Build app\""}}]}"#);
        progress.apply(r#"{"type":"GENERIC","status":"RUNNING","created_at":"2026-11-06T16:00:00Z","content":"Tool is running as a background task with task id: conv/task-7\nTask Description: cargo build"}"#);
        progress.apply(r#"{"type":"PLANNER_RESPONSE","source":"MODEL","tool_calls":[{"name":"schedule","args":{"Prompt":"\"Check task-7\"","TimerCondition":"\"conv/task-7\""}}]}"#);
        progress.apply(r#"{"type":"GENERIC","status":"RUNNING","created_at":"2026-11-06T16:00:01Z","content":"Tool is running as a background task with task id: conv/task-8\nTask Description: Timer: 3m (until 2026-11-06T16:03:01Z)\nPrompt: Check task-7"}"#);
        assert_eq!(progress.pending.get("conv/task-7").and_then(|t| t.activity.clone()).as_deref(), Some("Build app"));
        assert!(progress.pending.get("conv/task-8").is_some_and(|t| t.is_timer));
        progress.apply(r#"{"type":"SYSTEM_MESSAGE","content":"[Message] sender=conv/task-7 content=Task id \"conv/task-7\" finished with result"}"#);
        assert!(progress.pending.is_empty());
    }

    #[test]
    fn clearing_unread_in_agent_releases_held_task_immediately() {
        let mut monitor = DesktopTaskMonitor::new(None);
        let none = HashSet::new();
        let existing = Some(HashSet::from(["a".to_string(), "b".to_string()]));
        let mut sessions = HashMap::from([
            ("a".to_string(), session("a", 1_000, Some(1_010))),
            ("b".to_string(), session("b", 1_000, Some(1_005))),
        ]);
        assert!(monitor.agy.update(&sessions, &none, &none, false, 1_020_000).is_empty());

        // Turn finishes on `a` (which was already `shown_session_id`) while in background.
        sessions.insert("a".into(), session("a", 1_100, Some(1_010)));
        let unread_ids = monitor.agy.update(&sessions, &none, &none, false, 1_110_000);
        assert!(unread_ids.contains("a"));
        monitor.accept("antigravity", vec![unread("antigravity", "a", 1_100_000)], existing.clone(), 1_110_000);
        assert_eq!(monitor.publish("antigravity", 1_110_000).len(), 1);

        // User clears unread on `a` inside Antigravity (even while `b` also updates in the same poll).
        sessions.insert("a".into(), session("a", 1_100, Some(1_120)));
        sessions.insert("b".into(), session("b", 1_000, Some(1_120)));
        let unread_ids = monitor.agy.update(&sessions, &none, &none, true, 1_121_000);
        assert!(unread_ids.is_empty());
        monitor.accept("antigravity", vec![], existing, 1_121_000);
        assert!(monitor.publish("antigravity", 1_121_000).is_empty());

        // Codex activity timestamp in `.codex-global-state.json` also releases held task immediately.
        monitor.accept("codex", vec![unread("codex", "t1", 2_000)], None, 2_100);
        let state_json = serde_json::json!({
            "electron-persisted-atom-state": {
                "thread-user-activity-times-v1": {
                    "[\"local\",\"t1\"]": 2_500
                }
            }
        });
        monitor.codex_activity_ms = codex_activity_times(&state_json);
        monitor.accept("codex", vec![], None, 2_600);
        assert!(monitor.publish("codex", 2_600).is_empty());
    }
}
