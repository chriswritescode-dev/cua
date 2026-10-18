// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import type { UpdateState } from "@/bridge";

/** What the in-app update indicator shows for the host's updater. It is
 * quiet: only a found release shows anything. */
export interface UpdateView {
  label: string;
  /** How to get it: the host's rebuild instruction. */
  detail: string;
}

/** The indicator for `state`; null when there is nothing to show (idle,
 * checking, or a failed check: the next check tries again). */
export function updateView(state: UpdateState | undefined): UpdateView | null {
  if (state?.status !== "available") return null;
  return { label: "Update available", detail: state.instructions ?? state.message ?? "" };
}
