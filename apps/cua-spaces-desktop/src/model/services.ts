// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

// The account (the SwiftUI app's AppServices.swift), behind small
// interfaces so tests never touch the real session. Words and rows are the
// core's.
import type { AppHostAccount, AuthIdentity, AuthLike } from "../native/generated/index";

/** A started sign-in: the code to confirm (device flow), then the identity. */
export interface SignInAttempt {
  userCode: string | null;
  /** The page the sign-in finishes on (to open it again). */
  url: string | null;
  /** A browser opened on this machine (false: the page is to be opened by hand, on any device). */
  opened?: boolean;
  wait(): Promise<string | null>;
}

/** How a sign-in starts. */
export interface SignInOptions {
  /** The code flow: the person enters a code on any device, so it works when the browser cannot reach this app (a blocked loopback, another browser, a phone). */
  code?: boolean;
}

/** The signed-in account's claims, for the presence name and id. */
export interface AccountProfile {
  name?: string;
  email?: string;
  username?: string;
  subject?: string;
}

/** The Cua account. */
export interface AccountRunning {
  /** The signed-in identity, read without network access. */
  identity(): string | null;
  profile(): AccountProfile | null;
  /** Starts a sign-in (opens the browser). `code`: with a code to enter on any
   * device, for when the browser's own way back to the app does not work. */
  beginSignIn(opts?: SignInOptions): Promise<SignInAttempt>;
  signOut(): Promise<void>;
  /** The account's token (`force`: refresh it); null when signed out. */
  accessToken(force: boolean): Promise<string | null>;
}

const display = (i: AuthIdentity | undefined) => i?.display ?? i?.email ?? i?.username ?? null;

/** The cua SDK's auth: the same session as `cua auth login`. */
export class LiveAccount implements AccountRunning {
  /** `openUrl` opens a page in this machine's browser: false when there is none (or it would not start). */
  constructor(
    private readonly auth: AuthLike,
    private readonly openUrl: (url: string) => Promise<boolean>,
  ) {}

  private status() {
    try {
      const s = this.auth.status();
      return s.loggedIn ? s : null;
    } catch {
      return null;
    }
  }

  identity(): string | null {
    return display(this.status()?.identity);
  }

  profile(): AccountProfile | null {
    const i = this.status()?.identity;
    return i ? { name: i.name, email: i.email, username: i.username, subject: i.subject } : null;
  }

  /** The browser on this machine finishes the sign-in. Without one (a Linux
   * box with no browser), the device flow instead, as `cua auth login
   * --remote` does: its page opens on any device, with the code the page
   * shows. */
  async beginSignIn(opts?: SignInOptions): Promise<SignInAttempt> {
    let attempt = await this.auth.beginLogin(opts?.code ? "device" : undefined);
    const opened = attempt.url() ? await this.openUrl(attempt.url()) : false;
    if (!opened && attempt.method() === "browser") attempt = await this.auth.beginLogin("device");
    const url = attempt.url();
    return {
      userCode: attempt.userCode() ?? null,
      url: url || null,
      opened,
      wait: async () => display(await attempt.wait()),
    };
  }

  async signOut(): Promise<void> {
    await this.auth.logout();
  }

  async accessToken(force: boolean): Promise<string | null> {
    try {
      return await this.auth.accessToken(force);
    } catch (error) {
      // Signed out is no token; anything else (offline, the credential
      // vault) is the error itself, never a silent "not signed in".
      if ((error as { tag?: unknown }).tag === "Unauthenticated") return null;
      throw error;
    }
  }
}

/** What relay sharing is checked against: the account's id, email and name. */
export function hostAccount(account: AccountRunning): AppHostAccount | null {
  const who = account.identity();
  if (!who) return null;
  const p = account.profile();
  const name = p?.name?.trim() ? p.name : undefined;
  return { id: p?.subject, email: p?.email, display: name ?? who };
}
