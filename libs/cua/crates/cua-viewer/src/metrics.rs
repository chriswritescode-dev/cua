// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

//! Client-side latency metric primitives for the on-screen stats overlay.
//!
//! These used to live in `rcdp-dogfood`, which also persisted every bucket to
//! a local SQLite store. That persistence was dropped when rcdp moved into
//! cua-spacesd; only the in-memory aggregation the stats title needs
//! remains here.

use std::time::{SystemTime, UNIX_EPOCH};

/// Milliseconds since the Unix epoch, saturating instead of panicking.
pub fn unix_timestamp_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}

/// One aggregation window of client latency and throughput metrics.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MetricBucket {
    pub timestamp_ms: u64,
    pub duration_ms: u64,
    pub fps: f64,
    pub bitrate_mbps: f64,
    pub control_rtt_ms: Option<f64>,
    pub encode_p50_ms: Option<f64>,
    pub encode_p95_ms: Option<f64>,
    pub encode_p99_ms: Option<f64>,
    pub decode_p50_ms: Option<f64>,
    pub decode_p95_ms: Option<f64>,
    pub decode_p99_ms: Option<f64>,
    pub present_p50_ms: Option<f64>,
    pub present_p95_ms: Option<f64>,
    pub present_p99_ms: Option<f64>,
    pub input_ack_p50_ms: Option<f64>,
    pub input_ack_p95_ms: Option<f64>,
    pub input_ack_p99_ms: Option<f64>,
    pub host_dispatch_p50_ms: Option<f64>,
    pub host_dispatch_p95_ms: Option<f64>,
    pub host_dispatch_p99_ms: Option<f64>,
    pub input_to_present_p50_ms: Option<f64>,
    pub input_to_present_p95_ms: Option<f64>,
    pub input_to_present_p99_ms: Option<f64>,
    pub scroll_gap_p95_ms: Option<f64>,
    pub frames_received: u64,
    pub frames_presented: u64,
    pub client_frames_replaced: u64,
    pub server_frames_replaced: u64,
    pub network_incomplete_frames: u64,
    pub input_events_captured: u64,
    pub input_events_sent: u64,
    pub input_batches_sent: u64,
    pub max_input_in_flight: u32,
    pub max_input_queue_depth: u32,
    pub scroll_events_captured: u64,
    pub scroll_events_sent: u64,
}

/// Nearest-rank percentile over the finite samples, or `None` when empty.
pub fn percentile_f64(values: &[f64], percentile: f64) -> Option<f64> {
    let mut values = values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .collect::<Vec<_>>();
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let percentile = percentile.clamp(0.0, 1.0);
    let index = ((values.len() - 1) as f64 * percentile).ceil() as usize;
    values.get(index).copied()
}

#[cfg(test)]
mod tests {
    use super::percentile_f64;

    #[test]
    fn percentile_ignores_non_finite_and_handles_empty() {
        assert_eq!(percentile_f64(&[], 0.5), None);
        assert_eq!(percentile_f64(&[f64::NAN], 0.5), None);
        let samples = [4.0, 1.0, f64::INFINITY, 3.0, 2.0];
        assert_eq!(percentile_f64(&samples, 0.0), Some(1.0));
        assert_eq!(percentile_f64(&samples, 0.5), Some(3.0));
        assert_eq!(percentile_f64(&samples, 1.0), Some(4.0));
    }
}
