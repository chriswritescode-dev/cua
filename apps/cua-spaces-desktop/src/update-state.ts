// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

// Where an update is, for the in-app indicator (the page's `update.get`).
// A pure state machine over what electron-updater reports, kept free of
// Electron so it can be tested on its own. The updater only says whether a
// newer release exists; nothing is downloaded or installed, so the page
// reports it with the command that pulls the repository and rebuilds.

export type UpdateStatus = "idle" | "checking" | "available" | "error";

/** The `UpdateState` the page reads (apps/cua-spaces-web/src/bridge/contracts/settings.ts). */
export interface UpdateStateValue {
  status: UpdateStatus;
  /** The version this app runs. */
  currentVersion: string;
  /** The version found; null with none. */
  version: string | null;
  /** The GitHub release notes page for `version`. */
  notesUrl: string | null;
  /** How to update by hand; null unless an update is available. */
  instructions: string | null;
  /** Why the last check failed (`error` only). */
  message: string | null;
}

/** A background check waits this long after launch, so it never competes with starting up. */
export const UPDATE_STARTUP_DELAY_MS = 15_000;
/** And repeats at this pace while the app stays open. */
export const UPDATE_POLL_MS = 4 * 60 * 60 * 1000;

const RELEASES = "https://github.com/trycua/cua/releases/tag";

/** The release notes for a version: the repository's `cua-spaces-v<version>` tag. */
export function releaseNotesUrl(version: string): string {
  return `${RELEASES}/cua-spaces-v${encodeURIComponent(version.trim())}`;
}

const BUILD_SCRIPT: Partial<Record<NodeJS.Platform, string>> = { darwin: "dist:mac", win32: "dist:win", linux: "dist:linux" };

/** The command that updates this checkout and rebuilds the app. */
export function rebuildCommand(platform: NodeJS.Platform = process.platform): string {
  return `git pull && pnpm --dir apps/cua-spaces-desktop ${BUILD_SCRIPT[platform] ?? "dist:linux"}`;
}

/** What says a newer release exists. */
export function updateHeadline(version: string): string {
  return `A newer Cua Spaces release (${version}) is available`;
}

/** How to get it. */
export function rebuildDetail(platform: NodeJS.Platform = process.platform): string {
  return `Update by pulling the repository and rebuilding: ${rebuildCommand(platform)}`;
}

/** The headline and the rebuild advice, as one line. */
export function updateInstruction(version: string, platform: NodeJS.Platform = process.platform): string {
  return `${updateHeadline(version)}. ${rebuildDetail(platform)}`;
}

export const initialUpdateState = (currentVersion: string): UpdateStateValue => ({
  status: "idle",
  currentVersion,
  version: null,
  notesUrl: null,
  instructions: null,
  message: null,
});

export type UpdateEvent =
  | { type: "checking" }
  | { type: "available"; version: string }
  | { type: "none" }
  | { type: "error"; message: string };

/** The next state. A found update stays found through later checks and failures; a check that finds nothing clears it. */
export function reduceUpdate(s: UpdateStateValue, e: UpdateEvent): UpdateStateValue {
  const found = s.status === "available" && s.version !== null;
  switch (e.type) {
    case "checking":
      // A found update is not hidden by the next check.
      return s.status === "idle" || s.status === "error" ? { ...s, status: "checking", message: null } : s;
    case "available":
      if (found && s.version === e.version) return s;
      return {
        ...s,
        status: "available",
        version: e.version,
        notesUrl: releaseNotesUrl(e.version),
        instructions: updateInstruction(e.version),
        message: null,
      };
    case "none":
      return found ? s : { ...initialUpdateState(s.currentVersion) };
    case "error":
      // The found update is still there; the next poll retries the check.
      return found ? s : { ...s, status: "error", message: e.message };
  }
}
