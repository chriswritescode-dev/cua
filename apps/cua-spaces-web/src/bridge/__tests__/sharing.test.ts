// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { describe, expect, it } from "vitest";
import type { MachineRow } from "../contracts/host";
import { toMachines } from "../derive";
import { wizardEnv, wizardInitial, wizardView } from "../new-space";
import { notSharingOf, realLimits, stoppedSharingLine, withNotSharing } from "../sharing";
import { DEMO_NEW_SPACE_OPTIONS } from "../adapters/demo/new-space";
import { testCore, wasmBuilt } from "./testCore";

const NOW = 1_800_000_000;
const LINE = "gamma-4 Mac Studio stopped sharing: ask its owner to Resume sharing (or run `cua host start` there)";

const row = (over: Partial<MachineRow> & Pick<MachineRow, "id" | "name">): MachineRow => ({ via: "relay", online: true, os: "macos", limits: [], ...over });

describe("a machine online but not sharing", () => {
  it("is told from its limits, only while it is online, and is no limit", () => {
    const limits = withNotSharing([{ resource: "spaces", used: 1, limit: 4, reason: "" }], LINE);
    expect(notSharingOf(limits, true)).toBe(LINE);
    expect(notSharingOf(limits, false)).toBeUndefined();
    expect(notSharingOf(realLimits(limits), true)).toBeUndefined();
    expect(realLimits(limits)).toEqual([{ resource: "spaces", used: 1, limit: 4, reason: "" }]);
    // Said twice, listed once.
    expect(withNotSharing(limits, LINE).filter((l) => l.resource === "sharing")).toHaveLength(1);
    // The SDK's line without a reason still says it.
    expect(notSharingOf(withNotSharing([], ""), true)).toBe("Its owner stopped sharing it");
    expect(stoppedSharingLine("Studio")).toBe("Studio stopped sharing: ask its owner to Resume sharing (or run `cua host start` there)");
  });

  it("shows on the Machines page as online with why, with no pseudo limit", () => {
    const machines = toMachines([row({ id: "m1", name: "gamma-4 Mac Studio", limits: withNotSharing([], LINE), detail: "Unreachable · refused" })], []);
    expect(machines[0]).toMatchObject({ online: true, notSharing: LINE, detail: LINE, limits: [] });
    const plain = toMachines([row({ id: "m2", name: "Mac mini" })], []);
    expect(plain[0]).not.toHaveProperty("notSharing");
  });
});

describe.skipIf(!wasmBuilt)("the Machines page and New Space's Run on (wasm core)", () => {
  const rows: MachineRow[] = [
    { id: "this-mac", name: "This Mac", via: "local", online: true, os: "macos", current: true, limits: [] },
    // Connected and answering.
    row({ id: "ok", name: "Mac mini" }),
    // Connected, slow to answer: online with its limits unknown.
    row({ id: "slow", name: "Slow Mac", os: "macos" }),
    // The relay does not see it.
    row({ id: "gone", name: "Studio", online: false }),
    // Connected, but its owner stopped sharing it (gamma-4).
    row({ id: "gamma", name: "gamma-4 Mac Studio", limits: withNotSharing([], LINE) }),
  ];

  it("read one online signal, and say the same thing about a machine that stopped sharing", async () => {
    const core = await testCore();
    const machines = toMachines(rows, [], core, NOW);
    const env = wizardEnv(core, { options: null, clouds: null, defaultLocation: "local", cloudAvailable: false, machines });
    const view = wizardView(core, wizardInitial(core, env), env);
    const runOn = new Map(view.placements.map((p) => [p.id.replace(/^host:/, ""), p] as const));

    for (const m of machines.filter((m) => !m.current)) {
      const p = runOn.get(m.id)!;
      // Online on the page, never "(offline)" in Run on, and the other way round.
      expect(p.label.includes("(offline)"), `${m.name}: ${p.label}`).toBe(!m.online);
    }
    // A slow but connected host stays selectable.
    expect(runOn.get("slow")).toMatchObject({ label: "Slow Mac", enabled: true });
    expect(runOn.get("ok")).toMatchObject({ label: "Mac mini", enabled: true });
    expect(runOn.get("gone")).toMatchObject({ label: "Studio (offline)", enabled: false, detail: "Studio is offline." });

    // Stopped sharing: online, listed not sharing, with the one reason.
    const gamma = machines.find((m) => m.id === "gamma")!;
    expect(gamma).toMatchObject({ online: true, notSharing: LINE });
    expect(runOn.get("gamma")).toMatchObject({ label: "gamma-4 Mac Studio (not sharing)", enabled: false, detail: `${LINE}.` });
    expect(env.hosts!.find((h) => h.id === "gamma")!.online).toBe(true);
  });

  it("lists a host the SDK reports as not sharing the same way", async () => {
    const core = await testCore();
    // The SwiftUI host's own env (`Spaces.hosts()`): online, with the
    // refusal among its limits.
    const options = {
      ...DEMO_NEW_SPACE_OPTIONS,
      env: {
        defaultLocation: "local" as const,
        cloudAvailable: false,
        localAvailable: true,
        maxCpus: 8,
        hosts: [{ id: "gamma", name: "gamma-4 Mac Studio", via: "relay", online: true, os: "macos", limits: [{ resource: "sharing", used: 0, limit: 0, reason: LINE }] }],
      },
    };
    const env = wizardEnv(core, { options, clouds: null, defaultLocation: "local", cloudAvailable: false, machines: [] });
    const [, gamma] = wizardView(core, wizardInitial(core, env), env).placements;
    expect(gamma).toMatchObject({ id: "host:gamma", label: "gamma-4 Mac Studio (not sharing)", enabled: false, detail: `${LINE}.` });
  });
});
