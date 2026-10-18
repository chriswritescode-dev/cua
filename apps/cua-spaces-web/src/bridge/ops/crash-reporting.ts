// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

/**
 * `crashReporting.config`: whether the page may report its own errors, and
 * the settings to do it with. The host decides: `allowed` is true only while
 * usage data is on and its first-run notice was shown, and the DSN, release
 * and channel are the app's (config/spaces-crash-reporting.json). A host
 * with no answer (`unsupported`, `unimplemented`, an error) means off.
 *
 * - SwiftUI and Electron: the same method name, answered by the shell.
 * - Tauri and the demo host have no crash reporting.
 */

import { UnsupportedOperationError, type BridgeMode } from "../adapter";
import type { OpCoverage } from "../coverage";
import type { CrashReportingConfig } from "../contracts/host";

export interface CrashReportingOps {
  /** Whether the page may report its own errors, and the settings to do it with (never null: a host that can't says `allowed: false` or is `unsupported`). */
  "crashReporting.config": { args: Record<string, never>; result: CrashReportingConfig };
}

export const CRASH_REPORTING_OPERATIONS = ["crashReporting.config"] as const satisfies readonly (keyof CrashReportingOps)[];

const text = (v: unknown): v is string => typeof v === "string" && v.length > 0;

const OFF: CrashReportingConfig = { allowed: false, dsn: "", release: "", environment: "", shell: "" };

/** A host's answer as crash settings; anything malformed, or without a DSN, reads as off. */
export function crashConfigFromHost(raw: unknown): CrashReportingConfig {
  const c = raw as Partial<CrashReportingConfig> | null | undefined;
  if (!c || typeof c !== "object" || c.allowed !== true) return OFF;
  if (!text(c.dsn) || !text(c.release) || !text(c.environment) || !text(c.shell)) return OFF;
  return {
    allowed: true,
    dsn: c.dsn,
    release: c.release,
    environment: c.environment,
    shell: c.shell,
    ...(c.crashTest === "ui" && c.environment === "local" ? { crashTest: "ui" as const } : {}),
  };
}

/** Tauri and the demo host have no crash reporting. */
export function unsupportedCrashReportingOps(mode: BridgeMode) {
  return { "crashReporting.config": (): Promise<never> => Promise.reject(new UnsupportedOperationError(mode, "crashReporting.config")) };
}

/** SwiftUI and Electron: the shell answers. An older host (`unimplemented`) or any failure reads as off. */
export function webkitCrashReportingOps(request: <T>(method: "crashReporting.config", args?: Record<string, unknown>, wait?: number | null) => Promise<T>) {
  return { "crashReporting.config": () => request<unknown>("crashReporting.config", {}, 5_000).then(crashConfigFromHost, () => OFF) };
}

export const CRASH_REPORTING_COVERAGE = {
  "crashReporting.config": {
    webkit: { methods: ["crashReporting.config"] },
    tauri: [],
    unsupported: { tauri: "the Tauri app reports crashes from its own Rust process, not the page" },
  },
} as const satisfies Record<keyof CrashReportingOps, OpCoverage>;
