#!/bin/zsh
# Contract: workspace profiles keep their privacy and layering boundaries.
# - Private CGS/SkyLight symbols stay inside CGSSpaceManager (the isolated
#   adapter); the private AX window-ID bridge stays inside the catalog.
# - Services never touch UI types; the executor knows no menu items.
# - Numa never creates/destroys Spaces, quits apps, or closes windows.
# - Window titles are hints, never matching identity.
set -euo pipefail

repo_root="${0:A:h:h}"
core="$repo_root/Sources/GlideBoardCore"

fail() { echo "workspace_profiles: $1" >&2; exit 1 }

for symbol in CGSMainConnectionID CGSCopyManagedDisplaySpaces \
              CGSMoveWindowsToManagedSpace CGSManagedDisplayGetCurrentSpace \
              CGSManagedDisplaySetCurrentSpace CGSCopySpacesForWindows SkyLight; do
  leaked=$(grep -rl "$symbol" "$core" --include='*.swift' \
    | grep -v "CGSSpaceManager.swift" || true)
  [[ -z "$leaked" ]] || fail "$symbol leaked outside CGSSpaceManager.swift: $leaked"
done

leaked=$(grep -rl "_AXUIElementGetWindow" "$core" --include='*.swift' \
  | grep -v "WorkspaceWindowCatalog.swift" || true)
[[ -z "$leaked" ]] || fail "_AXUIElementGetWindow leaked outside the catalog: $leaked"

grep -q "unavailable(reason:" "$core/CGSSpaceManager.swift" \
  || fail "the adapter lost its disabled-capability path"
grep -q "case .unavailable" "$core/WorkspaceProfilesController.swift" \
  || fail "the menu no longer surfaces the disabled capability"

services=(WorkspaceProfileExecutor WorkspaceCaptureService WorkspacePlanBuilder
          WorkspaceProfileStore WorkspaceApplicationLauncher WorkspaceWindowCatalog
          WorkspaceWindowRecipeRegistry CGSSpaceManager WorkspaceProfileModel
          SpaceManaging DisplayConfigurationResolver WorkspaceUndoStore
          WorkspaceWindowMover)
for service in "${services[@]}"; do
  if grep -q "NSMenu\|NSAlert" "$core/$service.swift"; then
    fail "$service must stay UI-free (NSMenu/NSAlert belong to the controller)"
  fi
done

if grep -rn "CGSAddSpace\|CGSSpaceCreate\|CGSSpaceDestroy\|CGSRemoveSpace" \
    "$core" --include='*.swift'; then
  fail "Numa must never create or destroy Spaces"
fi
for file in "$core"/Workspace*.swift "$core/CGSSpaceManager.swift"; do
  if grep -n "\.terminate()\|forceTerminate\|kAXCloseButton" "$file"; then
    fail "$(basename "$file") must never quit apps or close windows"
  fi
done

if grep -in "title" "$core/WorkspacePlanBuilder.swift" | grep -v "never part of identity"; then
  fail "the plan builder must not read window titles"
fi

pure=(WorkspaceProfileModel WorkspacePlanBuilder SpaceManaging
      WorkspaceProfileStore WorkspaceUndoStore)
for file in "${pure[@]}"; do
  if grep -q "import AppKit" "$core/$file.swift"; then
    fail "$file is part of the pure core and must not import AppKit"
  fi
done

grep -q "workspaceProfiles.menuItem()" "$core/AppDelegate.swift" \
  || fail "the status menu must route through WorkspaceProfilesController"

grep -q 'appendingPathComponent("GlideBoard"' "$core/WorkspaceProfileStore.swift" \
  || fail "profiles must persist under the GlideBoard support directory"

echo "workspace_profiles: OK"
