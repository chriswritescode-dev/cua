// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { describe, expect, it } from "vitest";
import { FixtureUpdater } from "../src/model/updates";
import { initialUpdateState, rebuildCommand, reduceUpdate, releaseNotesUrl, updateInstruction, UPDATE_POLL_MS, UPDATE_STARTUP_DELAY_MS, type UpdateEvent } from "../src/update-state";

const run = (events: UpdateEvent[], from = initialUpdateState("0.9.2")) => events.reduce(reduceUpdate, from);

describe("the update state machine", () => {
  it("goes idle, checking and available, with the rebuild command", () => {
    let s = initialUpdateState("0.9.2");
    expect(s).toEqual({ status: "idle", currentVersion: "0.9.2", version: null, notesUrl: null, instructions: null, message: null });
    s = reduceUpdate(s, { type: "checking" });
    expect(s.status).toBe("checking");
    s = reduceUpdate(s, { type: "available", version: "0.9.3" });
    expect(s).toMatchObject({
      status: "available",
      version: "0.9.3",
      notesUrl: "https://github.com/trycua/cua/releases/tag/cua-spaces-v0.9.3",
      instructions: updateInstruction("0.9.3"),
    });
  });

  it("keeps a found update through later checks and failures", () => {
    const found = run([{ type: "available", version: "0.9.3" }]);
    expect(run([{ type: "checking" }], found)).toBe(found);
    expect(run([{ type: "none" }], found)).toBe(found);
    expect(run([{ type: "available", version: "0.9.3" }], found)).toBe(found);
    expect(run([{ type: "error", message: "offline" }], found)).toBe(found);
  });

  it("replaces the found update with a newer one", () => {
    const found = run([{ type: "available", version: "0.9.3" }]);
    expect(run([{ type: "available", version: "0.9.4" }], found)).toMatchObject({ status: "available", version: "0.9.4" });
  });

  it("a failure keeps the reason, and the next check starts clean", () => {
    const failed = run([{ type: "checking" }, { type: "error", message: "offline" }]);
    expect(failed).toMatchObject({ status: "error", message: "offline" });
    expect(reduceUpdate(failed, { type: "checking" })).toMatchObject({ status: "checking", message: null });
    expect(reduceUpdate(failed, { type: "none" })).toEqual(initialUpdateState("0.9.2"));
  });

  it("does not hide a found update behind the next check", () => {
    const found = run([{ type: "available", version: "0.9.3" }]);
    expect(reduceUpdate(found, { type: "checking" })).toBe(found);
  });

  it("names the platform's build script in the rebuild command", () => {
    expect(rebuildCommand("darwin")).toBe("git pull && pnpm --dir apps/cua-spaces-desktop dist:mac");
    expect(rebuildCommand("win32")).toBe("git pull && pnpm --dir apps/cua-spaces-desktop dist:win");
    expect(rebuildCommand("linux")).toBe("git pull && pnpm --dir apps/cua-spaces-desktop dist:linux");
    expect(updateInstruction("0.9.3", "win32")).toBe(
      "A newer Cua Spaces release (0.9.3) is available. Update by pulling the repository and rebuilding: git pull && pnpm --dir apps/cua-spaces-desktop dist:win",
    );
  });

  it("points at the repository's release tag", () => {
    expect(releaseNotesUrl(" 0.9.3-rc.4 ")).toBe("https://github.com/trycua/cua/releases/tag/cua-spaces-v0.9.3-rc.4");
  });

  it("checks shortly after launch, and every few hours", () => {
    expect(UPDATE_STARTUP_DELAY_MS).toBe(15_000);
    expect(UPDATE_POLL_MS).toBe(4 * 60 * 60 * 1000);
  });
});

describe("the fixture updater (what the bridge drives)", () => {
  it("counts checks and reports what the updater found", () => {
    const u = new FixtureUpdater();
    u.report({ type: "available", version: "0.9.3" });
    expect(u.state).toMatchObject({ status: "available", version: "0.9.3" });
    u.checkNow();
    expect(u.checks).toBe(1);
    expect(u.lastCheck).toEqual(expect.any(Number));
  });
});
