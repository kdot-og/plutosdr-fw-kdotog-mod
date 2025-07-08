#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/analogdevicesinc/plutosdr-fw.git"
TAG="v0.39"
BRANCH="revc-plus-rebase"
REPO_DIR="plutosdr-fw"
PATCH_DIR="./patches"

OLD_PATCH_DIR=${OLD_PATCH_DIR:?OLD_PATCH_DIR environment variable must be set}

# Resolve absolute paths before changing directories
OLD_PATCH_DIR=$(realpath "$OLD_PATCH_DIR")
mkdir -p "$PATCH_DIR"
PATCH_DIR=$(realpath "$PATCH_DIR")

# Configure identity globally so submodules inherit it
git config --global user.email "Hurricankaden@icloud.com"
git config --global user.name "kdot-og"

# Clone and checkout
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"

git fetch --tags
git config user.email "Hurricankaden@icloud.com"
git config user.name "kdot-og"

if ! git rev-parse "$BRANCH" >/dev/null 2>&1; then
    git checkout -b "$BRANCH" "$TAG"
else
    git checkout "$BRANCH"
fi

# Ensure submodules are available for patching
git submodule update --init --recursive

# Copy old patches if directories differ
if [ "$OLD_PATCH_DIR" != "$PATCH_DIR" ]; then
    cp "$OLD_PATCH_DIR"/*.diff "$PATCH_DIR"/
fi

applied=()
failed=()

for patch in "$PATCH_DIR"/*.diff; do
    name=$(basename "$patch" .diff)
    case $name in
        fw) target="." ;;
        buildroot|linux|hdl|u-boot-xlnx) target="$name" ;;
        *) echo "Unknown patch $patch" >&2; exit 1 ;;
    esac

    echo "Applying $(basename "$patch") in $target"
    (
        cd "$target"
        if git am --3way "$patch"; then
            applied+=("$(basename "$patch")")
        else
            git am --abort >/dev/null 2>&1 || true
            if git apply --reject --whitespace=fix "$patch"; then
                failed+=("$(basename "$patch")")
            else
                echo "Failed to apply $patch" >&2
                exit 1
            fi
        fi
    )
    echo
done

echo "Patches applied cleanly:"
for p in "${applied[@]}"; do
    echo "  $p"
done

echo "Patches with rejects:"
for p in "${failed[@]}"; do
    echo "  $p"
done

if [ "${#failed[@]}" -ne 0 ]; then
python3 - <<'PYEOF'
import sys, re, difflib, pathlib, os

hunk_re = re.compile(r'^@@ -(\d+)(,(\d+))? \+(\d+)(,(\d+))? @@')

for rej in pathlib.Path('.').rglob('*.rej'):
    target = rej.with_suffix('')
    with open(target) as f:
        lines = f.readlines()
    with open(rej) as f:
        diff_lines = f.readlines()

    i=0
    while i < len(diff_lines):
        if diff_lines[i].startswith('@@'):
            m = hunk_re.match(diff_lines[i].strip())
            old_start = int(m.group(1))
            old_len = int(m.group(3) or 1)
            i += 1
            old=[]
            new=[]
            while i < len(diff_lines) and not diff_lines[i].startswith('@@'):
                l = diff_lines[i]
                if l.startswith('-'):
                    old.append(l[1:])
                elif l.startswith('+'):
                    new.append(l[1:])
                else:
                    old.append(l[1:])
                    new.append(l[1:])
                i += 1
            pos = old_start -1
            search_range = range(max(0, pos-5), min(len(lines), pos+5)+1)
            applied=False
            for idx in search_range:
                if lines[idx:idx+len(old)] == old:
                    lines[idx:idx+len(old)] = new
                    applied=True
                    break
            if not applied:
                best_ratio=0
                best_idx=None
                for idx in search_range:
                    cand = lines[idx:idx+len(old)]
                    ratio = difflib.SequenceMatcher(None, cand, old).ratio()
                    if ratio > best_ratio:
                        best_ratio=ratio
                        best_idx=idx
                if best_idx is not None and best_ratio>0.4:
                    lines[best_idx:best_idx+len(old)] = new
    with open(target,'w') as f:
        f.writelines(lines)
    os.remove(rej)
PYEOF
fi

# Commit and generate new patch series
git add -A
if git diff --cached --quiet; then
    echo "No changes to commit"
else
    git commit -m "PlutoPlus patch-set rebased onto v0.39"
fi

git format-patch --root --output-directory ../rebased-patches
