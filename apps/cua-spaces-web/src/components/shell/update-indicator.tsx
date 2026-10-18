// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { DownloadIcon } from "lucide-react";

import { useSession, useUpdate } from "@/bridge";
import { Button } from "@/components/ui/button";
import { Menu } from "@/components/ui/menu";
import { updateView } from "./update-copy";

/**
 * Everything the indicator needs: the newer release the host found and how
 * to update. Nothing here downloads or installs: the host only checks, and
 * the instruction says how to pull the repository and rebuild.
 */
export function useUpdateIndicator() {
  const { data } = useUpdate();
  const { openExternal } = useSession();
  const view = updateView(data?.state);
  const notesUrl = data?.state.notesUrl ?? null;
  return {
    view,
    whatsNew: notesUrl ? () => void openExternal(notesUrl).catch(() => {}) : null,
  };
}

type UpdateUi = ReturnType<typeof useUpdateIndicator>;

function AvailableIcon() {
  return <DownloadIcon className="size-4" strokeWidth={1.75} aria-hidden />;
}

/**
 * One icon for a found release: its name on the trigger, the host's rebuild
 * instruction in the menu, and "What's new". Null while up to date, checking
 * or after a failed check.
 */
function UpdateMenu({ ui }: { ui: UpdateUi }) {
  if (!ui.view) return null;
  const button = (
    <Button variant="ghost" size="icon-sm" aria-label={ui.view.label} title={ui.view.detail || ui.view.label} data-update-icon="available">
      <AvailableIcon />
    </Button>
  );
  const label = ui.view.detail ? (
    <span className="block max-w-64 text-pretty select-text" data-update-instructions="">
      {ui.view.detail}
    </span>
  ) : undefined;
  if (!ui.whatsNew) return button;
  return <Menu trigger={button} label={label} items={[{ label: "What's new", onSelect: ui.whatsNew }]} />;
}

/** The sidebar's update icon, at the end of the account line. */
export function SidebarUpdateButton() {
  const ui = useUpdateIndicator();
  if (!ui.view) return null;
  return (
    <span data-update-indicator="available" role="status">
      <UpdateMenu ui={ui} />
    </span>
  );
}

/** The top bar's update icon, shown only while the sidebar (and its icon) is closed. */
export function TopBarUpdateIndicator() {
  const ui = useUpdateIndicator();
  if (!ui.view) return null;
  return (
    <span data-update-indicator="available">
      <UpdateMenu ui={ui} />
    </span>
  );
}
