use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

use crate::incremental::PROTOCOL_V2;
use crate::protocol::DownloadResponse;

const PLATFORMS: [&str; 4] = ["codex", "claude", "grok", "antigravity"];

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PlatformWeeklyResets {
    pub codex: Option<i64>,
    pub claude: Option<i64>,
    pub grok: Option<i64>,
    pub antigravity: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResetMetadataResponse {
    pub protocol_version: u32,
    pub resets: BTreeMap<String, i64>,
}

impl PlatformWeeklyResets {
    pub fn from_metadata(response: &ResetMetadataResponse, now_ms: i64) -> Self {
        if response.protocol_version != PROTOCOL_V2 || now_ms <= 0 {
            return Self::default();
        }
        let mut result = Self::default();
        for platform in PLATFORMS {
            result.set(
                platform,
                response
                    .resets
                    .get(platform)
                    .copied()
                    .filter(|value| *value > 0 && *value <= now_ms),
            );
        }
        result
    }

    pub fn from_download(response: &DownloadResponse, now_ms: i64) -> Self {
        if now_ms <= 0 {
            return Self::default();
        }
        let mut snapshots = response.snapshots.iter().collect::<Vec<_>>();
        snapshots.sort_by(|left, right| {
            right
                .received_at_ms
                .cmp(&left.received_at_ms)
                .then_with(|| left.device.id.cmp(&right.device.id))
        });

        let mut resets = Self::default();
        let mut codex_legacy_fallback = None;
        for remote in snapshots {
            for platform in PLATFORMS {
                if resets.get(platform).is_none() {
                    resets.set(platform, source_reset(&remote.snapshot, platform, now_ms));
                }
            }
            if codex_legacy_fallback.is_none() {
                codex_legacy_fallback = valid_reset(
                    remote
                        .snapshot
                        .get("weeklySinceReset")
                        .and_then(|value| value.get("startedAtMs")),
                    now_ms,
                );
            }
            if resets.codex.is_some()
                && resets.claude.is_some()
                && resets.grok.is_some()
                && resets.antigravity.is_some()
            {
                break;
            }
        }
        if resets.codex.is_none() {
            resets.codex = codex_legacy_fallback;
        }
        resets
    }

    pub fn with_codex_fallback(mut self, fallback: Option<i64>, now_ms: i64) -> Self {
        if self.codex.is_none() && fallback.is_some_and(|value| value > 0 && value <= now_ms) {
            self.codex = fallback;
        }
        self
    }

    fn get(self, platform: &str) -> Option<i64> {
        match platform {
            "codex" => self.codex,
            "claude" => self.claude,
            "grok" => self.grok,
            "antigravity" => self.antigravity,
            _ => None,
        }
    }

    fn set(&mut self, platform: &str, value: Option<i64>) {
        match platform {
            "codex" => self.codex = value,
            "claude" => self.claude = value,
            "grok" => self.grok = value,
            "antigravity" => self.antigravity = value,
            _ => {}
        }
    }
}

fn source_reset(snapshot: &Value, platform: &str, now_ms: i64) -> Option<i64> {
    snapshot
        .get("sources")?
        .as_array()?
        .iter()
        .filter(|source| source.get("platform").and_then(Value::as_str) == Some(platform))
        .find_map(|source| {
            valid_reset(
                source
                    .get("weeklySinceReset")
                    .and_then(|value| value.get("startedAtMs")),
                now_ms,
            )
        })
}

fn valid_reset(value: Option<&Value>, now_ms: i64) -> Option<i64> {
    value
        .and_then(Value::as_i64)
        .filter(|timestamp| *timestamp > 0 && *timestamp <= now_ms)
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use uuid::Uuid;

    use super::*;
    use crate::protocol::{DeviceDescriptor, DeviceOs, RemoteSnapshot, PROTOCOL_VERSION};

    fn remote(received_at_ms: i64, snapshot: Value) -> RemoteSnapshot {
        RemoteSnapshot {
            device: DeviceDescriptor {
                id: Uuid::new_v4(),
                name: "Test device".to_string(),
                os: DeviceOs::Windows,
                client_version: None,
            },
            generated_at_ms: received_at_ms - 1,
            received_at_ms,
            snapshot,
        }
    }

    #[test]
    fn maps_newest_valid_resets_for_all_helper_platforms() {
        let response = DownloadResponse {
            protocol_version: PROTOCOL_VERSION,
            snapshots: vec![
                remote(
                    100,
                    json!({"sources": [
                        {"platform": "codex", "weeklySinceReset": {"startedAtMs": 10}},
                        {"platform": "claude", "weeklySinceReset": {"startedAtMs": 20}},
                        {"platform": "grok", "weeklySinceReset": {"startedAtMs": 30}}
                    ]}),
                ),
                remote(
                    200,
                    json!({"sources": [
                        {"platform": "codex", "weeklySinceReset": {"startedAtMs": 40}},
                        {"platform": "claude", "weeklySinceReset": {"startedAtMs": 50}},
                        {"platform": "grok", "weeklySinceReset": {"startedAtMs": 60}}
                    ]}),
                ),
            ],
        };

        let resets = PlatformWeeklyResets::from_download(&response, 1_000);
        assert_eq!(resets.codex, Some(40));
        assert_eq!(resets.claude, Some(50));
        assert_eq!(resets.grok, Some(60));
    }

    #[test]
    fn missing_reset_metadata_degrades_to_no_helper_resets() {
        let response = DownloadResponse {
            protocol_version: PROTOCOL_VERSION,
            snapshots: vec![remote(100, json!({"sources": []}))],
        };
        assert_eq!(
            PlatformWeeklyResets::from_download(&response, 1_000),
            PlatformWeeklyResets::default()
        );
    }

    #[test]
    fn ignores_nonpositive_and_future_values_and_uses_codex_legacy_fallback() {
        let response = DownloadResponse {
            protocol_version: PROTOCOL_VERSION,
            snapshots: vec![
                remote(
                    300,
                    json!({
                        "weeklySinceReset": {"startedAtMs": 70},
                        "sources": [
                            {"platform": "codex", "weeklySinceReset": {"startedAtMs": 2_000}},
                            {"platform": "claude", "weeklySinceReset": {"startedAtMs": 0}},
                            {"platform": "grok", "weeklySinceReset": {"startedAtMs": -1}}
                        ]
                    }),
                ),
                remote(
                    200,
                    json!({"sources": [
                        {"platform": "claude", "weeklySinceReset": {"startedAtMs": 80}},
                        {"platform": "grok", "weeklySinceReset": {"startedAtMs": 3_000}}
                    ]}),
                ),
            ],
        };

        let resets = PlatformWeeklyResets::from_download(&response, 1_000);
        assert_eq!(resets.codex, Some(70));
        assert_eq!(resets.claude, Some(80));
        assert_eq!(resets.grok, None);
    }

    #[test]
    fn codex_source_metadata_is_preferred_over_a_newer_legacy_fallback() {
        let response = DownloadResponse {
            protocol_version: PROTOCOL_VERSION,
            snapshots: vec![
                remote(300, json!({"weeklySinceReset": {"startedAtMs": 70}})),
                remote(
                    200,
                    json!({"sources": [
                        {"platform": "codex", "weeklySinceReset": {"startedAtMs": 60}}
                    ]}),
                ),
            ],
        };

        let resets = PlatformWeeklyResets::from_download(&response, 1_000);
        assert_eq!(resets.codex, Some(60));
    }
}
