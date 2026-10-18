// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

// The page's own crash reports (`crashReporting.config`): whether the page
// may report its errors, and the DSN, release and channel to do it with.
// Reporting is allowed only while the machine's usage data is on and its
// first-run notice was shown, read from the same files and environment the
// main process read at start (`crash-reporting.ts`).
import { crashConsent, crashReportingAnswer, localConsentSource } from "../crash-reporting";
import type { Handlers } from "./host";

export function crashReportingMethods(): Handlers {
  return {
    "crashReporting.config": () => crashReportingAnswer(crashConsent(localConsentSource()).allowed),
  };
}
