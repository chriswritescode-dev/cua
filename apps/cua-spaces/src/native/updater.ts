// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

/**
 * In-app update check. On launch we quietly ask the release feed whether a
 * newer signed build exists and, if so, say how to get it: this build is
 * not updated in place. Everything is dynamically imported so the browser
 * and test builds (no Tauri, no plugins) simply no-op.
 *
 * The feed + signature are configured in `tauri.conf.json` under
 * `plugins.updater` (endpoint + pubkey).
 */
import { invoke } from "@tauri-apps/api/core";

/** How a newer release is installed: pull this checkout and rebuild it. */
export const UPDATE_REBUILD_COMMAND = "git pull && pnpm --dir apps/cua-spaces tauri build";

/** The line a found release shows. */
export function updateMessage(version: string): string {
  return `A newer Cua Spaces release (${version}) is available. Update by pulling the repository and rebuilding: ${UPDATE_REBUILD_COMMAND}`;
}

/**
 * Asks the release feed for a newer build and posts what it finds as a
 * system notification. Never fails startup: an absent updater, an offline
 * machine or an unconfigured feed is quiet.
 */
export async function checkForUpdateSilently(): Promise<string | null> {
  try {
    const { check } = await import("@tauri-apps/plugin-updater");
    const update = await check();
    if (!update) return null;
    const message = updateMessage(update.version);
    await invoke("devices_notify", { title: "Cua Spaces update available", body: message }).catch(() => {});
    return message;
  } catch {
    return null;
  }
}
