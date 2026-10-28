// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

//! Whole-display targets on macOS: the active CoreGraphics displays, in
//! global logical points (the coordinate space cua-driver's click and
//! pointer tools use), with the current mode's backing pixel size.
//! Capture goes through ScreenCaptureKit (`macos_capture::CaptureSource::
//! Display`), keyed by the same CGDirectDisplayID.
//!
//! An asleep display is absent from the active CoreGraphics list even though
//! it is still online, so a sleeping display is woken with a user-activity
//! declaration before enumerating; otherwise every caller sees no display at
//! all.

use std::time::{Duration, Instant};

use core_foundation::base::TCFType;
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::display::CGDisplay;
use cua_spacesd_provider_api::ProviderDisplay;

type IOPMAssertionID = u32;
type IOReturn = i32;

const K_IO_RETURN_SUCCESS: IOReturn = 0;
const K_IOPM_USER_ACTIVE_LOCAL: u32 = 0;
const WAKE_POLL_INTERVAL: Duration = Duration::from_millis(100);
const WAKE_TIMEOUT: Duration = Duration::from_secs(2);

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOPMAssertionDeclareUserActivity(
        name: CFStringRef,
        user_type: u32,
        assertion_id: *mut IOPMAssertionID,
    ) -> IOReturn;
    fn IOPMAssertionRelease(assertion_id: IOPMAssertionID) -> IOReturn;
}

/// Every active display, the main (menu bar) display first.
pub(crate) fn displays() -> Vec<ProviderDisplay> {
    let main = CGDisplay::main().id;
    let mut displays: Vec<ProviderDisplay> = active_displays()
        .into_iter()
        .filter_map(|id| display(id, id == main))
        .collect();
    displays.sort_by_key(|display| !display.primary);
    displays
}

/// The active display ids, waking a sleeping display first when CoreGraphics
/// reports none.
fn active_displays() -> Vec<u32> {
    let active = CGDisplay::active_displays().unwrap_or_default();
    if !active.is_empty() {
        return active;
    }
    wake_and_poll()
}

/// Declare local user activity to wake the display, then poll for it.
fn wake_and_poll() -> Vec<u32> {
    let name = CFString::from_static_string("Cua Spacesd: wake the display for capture");
    let mut assertion: IOPMAssertionID = 0;
    let status = unsafe {
        IOPMAssertionDeclareUserActivity(
            name.as_concrete_TypeRef(),
            K_IOPM_USER_ACTIVE_LOCAL,
            &mut assertion,
        )
    };
    if status != K_IO_RETURN_SUCCESS {
        tracing::warn!("could not wake the display: IOPMAssertionDeclareUserActivity {status}");
        return Vec::new();
    }
    let ids = poll_until_non_empty(
        || CGDisplay::active_displays().unwrap_or_default(),
        WAKE_POLL_INTERVAL,
        WAKE_TIMEOUT,
    );
    unsafe { IOPMAssertionRelease(assertion) };
    if ids.is_empty() {
        tracing::warn!("no active display within {WAKE_TIMEOUT:?} of waking the display");
    }
    ids
}

/// Poll `query` every `interval` until it is non-empty or `timeout` passes,
/// returning the last answer.
fn poll_until_non_empty(
    mut query: impl FnMut() -> Vec<u32>,
    interval: Duration,
    timeout: Duration,
) -> Vec<u32> {
    let deadline = Instant::now() + timeout;
    loop {
        let ids = query();
        if !ids.is_empty() {
            return ids;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return ids;
        }
        std::thread::sleep(interval.min(remaining));
    }
}

fn display(id: u32, primary: bool) -> Option<ProviderDisplay> {
    let cg = CGDisplay::new(id);
    let bounds = cg.bounds();
    let (width, height) = (bounds.size.width, bounds.size.height);
    if width < 1.0 || height < 1.0 {
        return None;
    }
    let mode = cg.display_mode();
    let (native_width_px, native_height_px, refresh_rate_hz) = match &mode {
        Some(mode) if mode.pixel_width() > 0 && mode.pixel_height() > 0 => (
            mode.pixel_width() as u32,
            mode.pixel_height() as u32,
            mode.refresh_rate().round().max(0.0) as u32,
        ),
        _ => (width.round() as u32, height.round() as u32, 0),
    };
    Some(ProviderDisplay {
        id: id.to_string(),
        name: format!("display-{id}"),
        primary,
        bounds: (bounds.origin.x, bounds.origin.y, width, height),
        native_width_px,
        native_height_px,
        scale_factor: backing_scale(native_width_px, width),
        refresh_rate_hz,
    })
}

/// Backing pixels per point, rounded to the nearest half (the same rule as
/// cua-driver's `get_screen_size`).
fn backing_scale(pixel_width: u32, point_width: f64) -> f64 {
    if pixel_width == 0 || point_width < 1.0 {
        return 1.0;
    }
    ((f64::from(pixel_width) / point_width) * 2.0)
        .round()
        .max(2.0)
        / 2.0
}

/// The CGDirectDisplayID behind a display id string.
pub(crate) fn parse_id(display_id: &str) -> Option<u32> {
    display_id.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backing_scale_rounds_to_halves() {
        assert_eq!(backing_scale(1024, 1024.0), 1.0);
        assert_eq!(backing_scale(2880, 1440.0), 2.0);
        assert_eq!(backing_scale(1511, 1007.0), 1.5);
        assert_eq!(backing_scale(0, 1024.0), 1.0);
    }

    #[test]
    fn display_ids_are_numeric() {
        assert_eq!(parse_id("69734272"), Some(69_734_272));
        assert_eq!(parse_id("primary"), None);
    }

    #[test]
    fn poll_returns_the_first_non_empty_answer() {
        let mut queries = 0;
        let ids = poll_until_non_empty(
            || {
                queries += 1;
                vec![7]
            },
            Duration::from_millis(1),
            Duration::from_secs(1),
        );
        assert_eq!(ids, vec![7]);
        assert_eq!(queries, 1);
    }

    #[test]
    fn poll_keeps_polling_until_a_display_appears() {
        let mut queries = 0;
        let ids = poll_until_non_empty(
            || {
                queries += 1;
                if queries < 3 {
                    Vec::new()
                } else {
                    vec![11]
                }
            },
            Duration::from_millis(1),
            Duration::from_secs(5),
        );
        assert_eq!(ids, vec![11]);
        assert_eq!(queries, 3);
    }

    #[test]
    fn poll_gives_up_empty_at_the_deadline() {
        let mut queries = 0;
        let ids = poll_until_non_empty(
            || {
                queries += 1;
                Vec::new()
            },
            Duration::from_millis(5),
            Duration::from_millis(20),
        );
        assert!(ids.is_empty());
        assert!(queries >= 2, "{queries} queries");
    }
}
