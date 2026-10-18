// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
// Before the redesign: public's test for this page, run with `spaces_redesign` off
// (the drift guard that keeps the default UI working).

import { vi as __vi } from "vitest";
__vi.stubEnv("VITE_CUA_FLAG_SPACES_REDESIGN", "0");
import { act, cleanup, fireEvent, render, renderHook, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { ReactNode } from "react";

import type { AgentSetupRow, Space } from "@/bridge";
import { BridgeContext, type BridgeContextValue } from "@/bridge/BridgeProvider";
import { RunAgentDialog, runAgentPrompt } from "@/legacy/components/agents/run-agent-dialog";
import { suggestedTask, useFirstRunStep, useFirstSpaceMilestones } from "@/components/first-run-guide";
import { SpaceReadyCard, useAgentOffer } from "@/legacy/components/space-ready-card";
import { EXPLAINED_KEY, needsExplainer, TeleportExplainer } from "@/components/teleport/explainer";

const nav = vi.fn();
let rows: AgentSetupRow[] = [];
const configureAgents = vi.fn(async () => rows);

vi.mock("@tanstack/react-router", () => ({ useNavigate: () => nav }));
vi.mock("@/bridge", async (orig) => ({
  ...(await orig<typeof import("@/bridge")>()),
  useAgents: () => ({ agentSetup: async () => rows, configureAgents }),
}));

const space = { id: "s1", name: "Research" } as Space;
const row = (over: Partial<AgentSetupRow>): AgentSetupRow => ({ agent: "claude-code", name: "Claude Code", installed: true, configured: false, ...over }) as AgentSetupRow;

beforeEach(() => {
  nav.mockReset();
  configureAgents.mockClear();
  localStorage.clear();
});
afterEach(cleanup);

describe("SpaceReadyCard", () => {
  it("says the first Space is ready, names the agents found, and offers one real task", async () => {
    rows = [row({}), row({ agent: "codex", name: "Codex", configured: true }), row({ agent: "hermes", name: "Hermes", installed: false })];
    const onRun = vi.fn();
    render(<SpaceReadyCard space={space} onRun={onRun} />);
    expect(screen.getByRole("heading", { name: "Your first Space is ready" })).toBeTruthy();
    expect(await screen.findByText(/We found Claude Code and Codex on this computer/)).toBeTruthy();
    expect(screen.getByText("Run a project's tests on a clean Linux computer")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Try this task" }));
    expect(onRun).toHaveBeenCalledOnce();
    expect(onRun.mock.calls[0]![0].prompt).toMatch(/run its tests/);
    expect(document.body.textContent).not.toMatch(/relay|MCP|\bhost\b|weather|flight|pizza/i);
  });

  it("opens the Space", async () => {
    rows = [];
    render(<SpaceReadyCard space={space} onRun={() => {}} />);
    fireEvent.click(await screen.findByRole("button", { name: "Open Research" }));
    expect(nav).toHaveBeenCalledWith({ to: "/spaces/$spaceId", params: { spaceId: "s1" } });
  });

  it("says how to connect when no agent is found, and can be closed", async () => {
    rows = [];
    const onDismiss = vi.fn();
    render(<SpaceReadyCard space={space} onRun={() => {}} onDismiss={onDismiss} />);
    expect(await screen.findByText(/Connect an agent such as Claude Code or Codex/)).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Not now" }));
    expect(onDismiss).toHaveBeenCalledOnce();
  });
});

describe("the guided first run's steps", () => {
  const wrapper = ({ children }: { children?: ReactNode }) => {
    const value = { mode: "electron", core: {}, adapter: null, store: null, ready: Promise.resolve(null) } as unknown as BridgeContextValue;
    return <BridgeContext.Provider value={value}>{children}</BridgeContext.Provider>;
  };
  const marks = (step: string) => localStorage.getItem(`cua.firstRun.${step}`);
  const s = (status: string) => ({ id: "s1", name: "Research", os: "linux", status }) as unknown as Space;

  it("marks shown, created, ready and task started once each", async () => {
    const step = renderHook(() => useFirstRunStep(), { wrapper }).result.current;
    act(() => step("guide_shown"));
    const m = renderHook(({ list }) => useFirstSpaceMilestones(list), { wrapper, initialProps: { list: [s("provisioning")] } });
    m.rerender({ list: [s("running")] });
    m.rerender({ list: [s("running")] });
    act(() => step("task_started"));
    act(() => step("task_started"));
    await waitFor(() => expect(["guide_shown", "space_created", "space_ready", "task_started"].map(marks)).toEqual(["1", "1", "1", "1"]));
  });

  it("does not mark created or ready on an install that never showed the guide", async () => {
    renderHook(() => useFirstSpaceMilestones([s("running")]), { wrapper });
    await Promise.resolve();
    expect(marks("space_created")).toBeNull();
    expect(marks("space_ready")).toBeNull();
  });

  it("suggests real work on a clean computer, for the Space's system", () => {
    expect(suggestedTask({ ...s("running"), os: "macos" } as Space).title).toBe("Run a project's tests on a clean Mac");
    expect(suggestedTask(s("running")).prompt).toContain('"Research"');
  });

  it("the run dialog shows the suggested request", async () => {
    rows = [row({ configured: true })];
    const { prompt } = suggestedTask(s("running"));
    render(<RunAgentDialog open space={space} onOpenChange={() => {}} prompt={prompt} />);
    expect(await screen.findByText(prompt)).toBeTruthy();
  });
});

describe("useAgentOffer", () => {
  const wrapper = ({ children }: { children?: ReactNode }) => {
    const value = { mode: "electron", core: {}, adapter: null, store: null, ready: Promise.resolve(null) } as unknown as BridgeContextValue;
    return <BridgeContext.Provider value={value}>{children}</BridgeContext.Provider>;
  };

  it("is shown once, then not after completed", async () => {
    const { result } = renderHook(() => useAgentOffer(true), { wrapper });
    await waitFor(() => expect(localStorage.getItem("cua.agentOffer.shown")).toBe("1"));
    act(() => result.current.clicked());
    act(() => result.current.completed());
    expect(result.current.visible).toBe(false);
    expect(renderHook(() => useAgentOffer(true), { wrapper }).result.current.visible).toBe(false);
  });

  it("stays closed after Not now", async () => {
    const first = renderHook(() => useAgentOffer(true), { wrapper });
    await waitFor(() => expect(localStorage.getItem("cua.agentOffer.shown")).toBe("1"));
    act(() => first.result.current.dismiss());
    expect(first.result.current.visible).toBe(false);
    expect(renderHook(() => useAgentOffer(true), { wrapper }).result.current.visible).toBe(false);
  });

  it("is hidden until a Space is ready", () => {
    expect(renderHook(() => useAgentOffer(false), { wrapper }).result.current.visible).toBe(false);
    expect(localStorage.getItem("cua.agentOffer.shown")).toBeNull();
  });
});

describe("RunAgentDialog", () => {
  it("shows the request to paste when an agent is connected", async () => {
    rows = [row({ configured: true })];
    render(<RunAgentDialog open space={space} onOpenChange={() => {}} />);
    expect((await screen.findByText(runAgentPrompt("Research"))).hasAttribute("data-run-agent-prompt")).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Copy and see Agents" }));
    expect(nav).toHaveBeenCalledWith({ to: "/agents" });
  });

  it("Connect opens Connectors with the agent in view (Cua connects only where the person says so)", async () => {
    rows = [row({})];
    const closed = vi.fn();
    render(<RunAgentDialog open space={space} onOpenChange={closed} />);
    fireEvent.click(await screen.findByRole("button", { name: "Connect Claude Code" }));
    await waitFor(() => expect(nav).toHaveBeenCalledWith({ to: "/settings/connectors", search: { app: "claude-code" } }));
    expect(closed).toHaveBeenCalledWith(false);
    expect(configureAgents).not.toHaveBeenCalled();
  });

  it("says so when no agent is installed", async () => {
    rows = [];
    render(<RunAgentDialog open space={space} onOpenChange={() => {}} onManual={() => {}} />);
    expect(await screen.findByRole("button", { name: "Show me how" })).toBeTruthy();
  });
});

describe("Teleport explainer", () => {
  it("explains teleport and the Mac's permission prompt in plain words", () => {
    render(<TeleportExplainer />);
    const text = screen.getByText(/Your Mac will ask for permission/).closest("p")?.textContent ?? "";
    expect(text).toMatch(/Keychain/);
    expect(document.body.textContent).not.toMatch(/relay|MCP|\bhost\b|machine/i);
  });

  it("shows once on a Mac, never elsewhere", () => {
    const mac = vi.spyOn(globalThis.navigator, "platform", "get").mockReturnValue("MacIntel");
    expect(needsExplainer()).toBe(true);
    localStorage.setItem(EXPLAINED_KEY, "1");
    expect(needsExplainer()).toBe(false);
    mac.mockRestore();
  });
});
