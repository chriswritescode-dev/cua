// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { DownloadIcon } from "lucide-react";

import { useSession, useUpdate } from "@/bridge";
import { Button } from "@/components/ui/button";
import { Menu } from "@/components/ui/menu";
import { cn } from "@/lib/utils";
import { useRelayAllowanceShowing } from "./relay-allowance-notice";
import { updateView } from "./update-copy";

/**
 * Everything the indicator needs: the newer release the host found and how
 * to update. Nothing here downloads or installs: the host only checks, and
 * the instruction says how to pull the repository and rebuild.
 */
function useUpdateIndicator() {
  const { data } = useUpdate();
  const { openExternal } = useSession();
  const view = updateView(data?.state);
  const notesUrl = data?.state.notesUrl ?? null;
  return {
    view,
    whatsNew: notesUrl ? () => void openExternal(notesUrl).catch(() => {}) : null,
  };
}

function AvailableIcon() {
  return <DownloadIcon className="size-4" strokeWidth={1.75} aria-hidden />;
}

/**
 * The sidebar's update line, above the account: the newer version and the
 * host's rebuild instruction, with a "What's new" link. While the relay
 * allowance notice (an upgrade prompt) is open it shrinks to an icon, so
 * the two are never both open.
 */
export function SidebarUpdateIndicator() {
  const ui = useUpdateIndicator();
  const upsellOpen = useRelayAllowanceShowing();
  if (!ui.view) return null;
  if (upsellOpen) return <UpdateMenu ui={ui} compact />;
  return (
    <div data-update-indicator="available" role="status" className="border-t px-3 py-2.5">
      <div className="flex items-start gap-2.5">
        <span className="mt-0.5 text-muted-foreground">
          <AvailableIcon />
        </span>
        <div className="min-w-0 flex-1">
          <div className="text-xs font-medium">{ui.view.label}</div>
          {ui.view.detail ? <p className="mt-0.5 text-2xs text-pretty text-muted-foreground select-text">{ui.view.detail}</p> : null}
          {ui.whatsNew ? (
            <button type="button" data-update-whats-new="" onClick={ui.whatsNew} className="mt-1.5 text-2xs text-muted-foreground underline decoration-dotted underline-offset-4 hover:text-foreground">
              What's new
            </button>
          ) : null}
        </div>
      </div>
    </div>
  );
}

/** One icon with the same link in a menu: the top bar (sidebar closed) and the compact sidebar. */
function UpdateMenu({ ui, compact = false }: { ui: ReturnType<typeof useUpdateIndicator>; compact?: boolean }) {
  if (!ui.view) return null;
  const button = (
    <Button variant="ghost" size="icon-sm" aria-label={ui.view.label} title={ui.view.detail || ui.view.label} data-update-icon="" className={cn("text-muted-foreground", compact && "w-full justify-start gap-2 px-1.5")}>
      <AvailableIcon />
      {compact ? <span className="truncate text-2xs">{ui.view.label}</span> : null}
    </Button>
  );
  if (!ui.whatsNew) return button;
  return <Menu trigger={button} items={[{ label: "What's new", onSelect: ui.whatsNew }]} />;
}

/** The top bar's update icon, shown only while the sidebar (and its line) is closed. */
export function TopBarUpdateIndicator() {
  const ui = useUpdateIndicator();
  if (!ui.view) return null;
  return (
    <span data-update-indicator="available">
      <UpdateMenu ui={ui} />
    </span>
  );
}
