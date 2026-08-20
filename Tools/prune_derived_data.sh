#!/bin/bash
# Remove orphaned Xcode DerivedData folders.
#
# Xcode derives the folder name from the absolute project path, so every git
# worktree that ever ran a build owns its own ~150 MB tree. Deleting the
# worktree does not delete the tree, and the leftovers are what fill the disk.
#
# Default is a dry run. Pass --delete to actually remove.
# Pass --all to consider every project, not just LocalDictation.

set -euo pipefail

root="${HOME}/Library/Developer/Xcode/DerivedData"
prefix="LocalDictation-"
delete=0

for arg in "$@"; do
    case "$arg" in
        --delete) delete=1 ;;
        --all) prefix="" ;;
        -h|--help)
            echo "usage: $(basename "$0") [--delete] [--all]"
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$root" ]]; then
    echo "No DerivedData directory at ${root}."
    exit 0
fi

found=0

for folder in "${root}/${prefix}"*; do
    [[ -d "$folder" ]] || continue

    plist="${folder}/info.plist"
    # Shared caches (ModuleCache.noindex, SDKStatCaches.noindex, ...) carry no
    # info.plist. They belong to no project, so leave them alone.
    [[ -f "$plist" ]] || continue

    workspace="$(plutil -extract WorkspacePath raw -o - "$plist" 2>/dev/null || true)"
    [[ -n "$workspace" ]] || continue

    # The workspace is the .xcodeproj / .xcworkspace itself; its parent is the
    # checkout. A missing parent means the worktree or clone is gone.
    [[ -e "$workspace" ]] && continue

    size="$(du -sh "$folder" | cut -f1)"
    found=$((found + 1))

    if [[ "$delete" == "1" ]]; then
        rm -rf "$folder"
        printf 'removed %-6s %s  (was %s)\n' "$size" "$(basename "$folder")" "$workspace"
    else
        printf 'orphan  %-6s %s  (missing %s)\n' "$size" "$(basename "$folder")" "$workspace"
    fi
done

if [[ "$found" == "0" ]]; then
    echo "No orphaned DerivedData folders."
elif [[ "$delete" != "1" ]]; then
    echo
    echo "${found} orphaned folder(s). Re-run with --delete to remove them."
fi
