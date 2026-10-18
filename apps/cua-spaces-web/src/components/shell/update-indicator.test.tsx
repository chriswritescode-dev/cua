// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { createDemoAdapter } from "@/bridge/adapters/demo";
import { noCore } from "@/bridge/__tests__/testCore";
import { BridgeProvider, type DataAdapter, type UpdateState } from "@/bridge";

const upsell = vi.hoisted(() => ({ open: false }));
vi.mock("./relay-allowance-notice", () => ({ useRelayAllowanceShowing: () => upsell.open }));

import { SidebarUpdateIndicator, TopBarUpdateIndicator } from "./update-indicator";

afterEach(() => {
  cleanup();
  upsell.open = false;
});

const NOTES = "https://github.com/trycua/cua/releases/tag/cua-spaces-v0.9.3";
const INSTRUCTION = "A newer Cua Spaces release (0.9.3) is available. Update by pulling the repository and rebuilding: git pull && pnpm --dir apps/cua-spaces tauri build";
const available: Partial<UpdateState> = { status: "available", version: "0.9.3", notesUrl: NOTES, instructions: INSTRUCTION };

/** The demo host with an updater in `update`, recording what the page asks of it. */
function host(update: Partial<UpdateState> | undefined) {
  const demo = createDemoAdapter({ latencyMs: 0, update });
  const calls: string[] = [];
  const opened: string[] = [];
  const adapter: DataAdapter = {
    ...demo,
    call: (op, args) => {
      calls.push(op);
      if (op === "session.openExternal") {
        opened.push((args as { url: string }).url);
        return Promise.resolve(null) as ReturnType<typeof demo.call>;
      }
      return demo.call(op, args);
    },
  };
  const view = (ui = <SidebarUpdateIndicator />) =>
    render(
      <BridgeProvider adapter={adapter} core={noCore}>
        {ui}
      </BridgeProvider>,
    );
  return { demo, calls, opened, view };
}

describe("<SidebarUpdateIndicator>", () => {
  it("shows nothing while up to date", async () => {
    const { view, calls } = host(undefined);
    view();
    await waitFor(() => expect(calls).toContain("update.get"));
    await act(() => new Promise((r) => setTimeout(r, 10)));
    expect(document.querySelector("[data-update-indicator]")).toBeNull();
  });

  it("shows the found release and the host's rebuild instruction, with no install button", async () => {
    const { view, opened } = host(available);
    view();
    const row = await screen.findByRole("status");
    expect(row.textContent).toContain("Update available");
    expect(row.textContent).toContain("git pull && pnpm --dir apps/cua-spaces tauri build");
    expect(screen.queryByRole("button", { name: /Restart|Install/ })).toBeNull();
    fireEvent.click(screen.getByText("What's new"));
    await waitFor(() => expect(opened).toEqual([NOTES]));
  });

  it("steps back to an icon while an upgrade prompt is open", async () => {
    upsell.open = true;
    const { view } = host(available);
    view();
    expect(await screen.findByRole("button", { name: "Update available" })).toBeTruthy();
    expect(screen.queryByText("What's new")).toBeNull();
  });

  it("shows nothing on a host with no updater (the call is unsupported)", async () => {
    const demo = createDemoAdapter({ latencyMs: 0 });
    const adapter: DataAdapter = { ...demo, call: (op, args) => (op === "update.get" ? Promise.reject(Object.assign(new Error("unsupported"), { code: "unsupported" })) : demo.call(op, args)) } as DataAdapter;
    render(
      <BridgeProvider adapter={adapter} core={noCore}>
        <SidebarUpdateIndicator />
      </BridgeProvider>,
    );
    await act(() => new Promise((r) => setTimeout(r, 10)));
    expect(document.querySelector("[data-update-indicator]")).toBeNull();
  });
});

describe("<TopBarUpdateIndicator>", () => {
  it("is one icon with the same name, for when the sidebar is closed", async () => {
    const { view } = host(available);
    view(<TopBarUpdateIndicator />);
    expect(await screen.findByRole("button", { name: "Update available" })).toBeTruthy();
  });
});
