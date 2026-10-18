// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

// Settings → About (the SwiftUI app's UpdatesModel.swift): the core's
// `AboutInput` over the updater's state, the channel saved in the app
// settings (`AppSettings.updateChannel`) and Check Now. The Electron updater
// (`src/updater.ts`, electron-updater) stands where Sparkle does in the Swift
// app; it only finds a newer release, which is installed by pulling the
// repository and rebuilding (update-state.ts).
import * as os from "node:os";
import type { AppAboutInput, AppUpdateChannel } from "../native/generated/index";
import type { Native } from "../native/load";
import { initialUpdateState, reduceUpdate, type UpdateEvent, type UpdateStateValue } from "../update-state";

/** What About drives: electron-updater in a packaged app, an in-memory one in tests. */
export interface UpdaterDriving {
  /** Checks on its own. */
  automaticallyChecks: boolean;
  /** The last check (ms), or null: never. */
  readonly lastCheck: number | null;
  /** Check Now can run (false while a check runs). */
  readonly canCheck: boolean;
  /** The channel it checks (`stable` or `beta`). */
  channel: "stable" | "beta";
  /** Called after any of the above changes. */
  onChange: (() => void) | null;
  /** Checks now; what it finds shows in the in-app indicator (a failure of this check, in a window). */
  checkNow(): void;
  /** Where the update is (found): the in-app indicator. */
  readonly state: UpdateStateValue;
}

/** An in-memory updater (tests): nothing is checked or stored. */
export class FixtureUpdater implements UpdaterDriving {
  automaticallyChecks = true;
  lastCheck: number | null;
  canCheck = true;
  channel: "stable" | "beta" = "stable";
  onChange: (() => void) | null = null;
  checks = 0;
  state: UpdateStateValue = initialUpdateState("0.0.0");
  constructor(lastCheck: number | null = null) {
    this.lastCheck = lastCheck;
  }
  checkNow() {
    this.checks += 1;
    this.lastCheck = Date.now();
    this.onChange?.();
  }
  /** Feeds what electron-updater would report (tests). */
  report(event: UpdateEvent) {
    this.state = reduceUpdate(this.state, event);
    this.onChange?.();
  }
}

/** The version and machine lines the pane shows. */
export interface AboutBundleInfo {
  version: string;
  build: string;
  /** "macOS 26.0 (arm64)", "Windows 11 (x64)", "Linux 6.8 (x64)". */
  os: string;
}

const PLATFORM: Partial<Record<NodeJS.Platform, string>> = { darwin: "macos", win32: "windows", linux: "linux" };

/** This machine for an issue report, as the Swift app words it. */
export function osLine(platform: NodeJS.Platform = process.platform, release = os.release(), arch: string = process.arch, version?: string): string {
  const cpu = arch === "x64" ? (platform === "darwin" ? "x86_64" : "x64") : arch;
  if (platform === "darwin") {
    // Darwin 20 to 24 are macOS 11 to 15; Darwin 25 is macOS 26.
    const [major, minor] = release.split(".").map((n) => Number.parseInt(n, 10));
    const mac = major === undefined || Number.isNaN(major) || major < 20 ? release : `${major >= 25 ? major + 1 : major - 9}.${minor ?? 0}`;
    return `macOS ${version ?? mac} (${cpu})`;
  }
  if (platform === "win32") {
    // Build 22000 and later is Windows 11.
    const build = Number.parseInt(release.split(".")[2] ?? "0", 10);
    return `Windows ${build >= 22000 ? "11" : "10"} (${cpu})`;
  }
  return `Linux ${release.split("-")[0]} (${cpu})`;
}

export function dateText(ms: number): string {
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(ms));
}

export class UpdatesModel {
  /** The chosen channel (saved in the app settings). */
  channel: AppUpdateChannel;
  private readonly listeners = new Set<() => void>();

  constructor(
    private readonly native: Native,
    readonly updater: UpdaterDriving | null,
    private readonly info: AboutBundleInfo,
    channel: AppUpdateChannel,
    private readonly saveChannel: (c: AppUpdateChannel) => void,
    private readonly platform: NodeJS.Platform = process.platform,
  ) {
    this.channel = channel;
    if (updater) {
      updater.channel = this.channelWord;
      updater.onChange = () => this.changed();
    }
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed(): void {
    for (const l of [...this.listeners]) l();
  }

  /** The in-app indicator's state; idle with no updater (a development run). */
  get updateState(): UpdateStateValue {
    return this.updater?.state ?? initialUpdateState(this.info.version);
  }

  get channelWord(): "stable" | "beta" {
    return this.channel === this.native.AppUpdateChannel.Beta ? "beta" : "stable";
  }

  /** What the pane is built from: the app, and the updater's state. */
  get input(): AppAboutInput {
    const u = this.updater;
    return {
      platform: PLATFORM[this.platform] ?? "macos",
      version: this.info.version,
      build: this.info.build,
      os: this.info.os,
      updater: u !== null,
      autoCheck: u?.automaticallyChecks ?? false,
      channel: this.channel,
      lastCheck: u?.lastCheck != null ? dateText(u.lastCheck) : undefined,
      checking: !(u?.canCheck ?? true),
    };
  }

  setAutoCheck(on: boolean): void {
    if (this.updater) this.updater.automaticallyChecks = on;
    this.changed();
  }

  choose(id: string): void {
    this.channel = id === "beta" ? this.native.AppUpdateChannel.Beta : this.native.AppUpdateChannel.Stable;
    if (this.updater) this.updater.channel = this.channelWord;
    this.saveChannel(this.channel);
    this.changed();
  }

  checkNow(): void {
    this.updater?.checkNow();
  }
}
