// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { useEffect } from "react";

import { upgradeLink, useBridge, usePlanLimitNotice, useSession } from "@/bridge";
import { setErrorAction } from "@/components/ui/toast";

/**
 * Puts Upgrade on the toast of a failed action when the failure is the
 * relay refusing a new live session over the plan's cap ("You're using 5 of
 * 5 live sessions on Pro. Close one or upgrade to Teams."). The sentence is
 * the error's own; the button opens the plan's page on the account app.
 * Renders nothing.
 *
 * The link says where it opened from (`?from=app_create` for a Space
 * create's toast, `app_connect` for opening or starting one).
 */
export function PlanLimitToastAction() {
  const noticeFor = usePlanLimitNotice();
  const { core } = useBridge();
  const { openExternal } = useSession();
  useEffect(() => {
    setErrorAction((text, group) => {
      const notice = noticeFor(text);
      const url = notice?.upgradeUrl;
      if (!notice || !url) return null;
      const surface = group === "create" ? "app_create" : "app_connect";
      return {
        label: notice.upgrade,
        onClick: () => void openExternal(upgradeLink(core, url, surface)).catch(() => {}),
      };
    });
    return () => setErrorAction(null);
  }, [noticeFor, openExternal, core]);
  return null;
}
