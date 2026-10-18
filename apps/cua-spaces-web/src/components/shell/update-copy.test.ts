// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { describe, expect, it } from "vitest";

import type { UpdateState } from "@/bridge";
import { updateView } from "./update-copy";

const base: UpdateState = { status: "idle", currentVersion: "0.9.2", version: null, notesUrl: null, message: null };
const INSTRUCTION = "A newer Cua Spaces release (0.9.3) is available. Update by pulling the repository and rebuilding: git pull && pnpm --dir apps/cua-spaces tauri build";

describe("updateView", () => {
  it("is quiet while idle, checking or failed", () => {
    expect(updateView(undefined)).toBeNull();
    for (const status of ["idle", "checking", "error"] as const) expect(updateView({ ...base, status, message: "offline" })).toBeNull();
  });

  it("shows the found release with the host's rebuild instruction", () => {
    expect(updateView({ ...base, status: "available", version: "0.9.3", instructions: INSTRUCTION })).toEqual({
      label: "Update available",
      detail: INSTRUCTION,
    });
  });

  it("falls back to the host's message", () => {
    expect(updateView({ ...base, status: "available", version: "0.9.3", message: INSTRUCTION })).toEqual({
      label: "Update available",
      detail: INSTRUCTION,
    });
  });
});
