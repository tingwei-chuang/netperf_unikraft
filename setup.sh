#!/usr/bin/env bash
# Clone Unikraft + libs at the pinned commits this app was developed against,
# and apply the patches under ./patches/. Idempotent — safe to re-run.
#
# Run once after `git clone`, before `make` in apps/netperf.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# Pinned upstream commits. Bump after re-testing.
UNIKRAFT_REPO=https://github.com/NatsuCamellia/unikraft.git
# vsock branch head (see unikraft-vsock/.gitmodules)
UNIKRAFT_SHA=bea08b49ae0c0dace15a34eaeb3c61e739cb3b02

LWIP_REPO=https://github.com/unikraft/lib-lwip.git
LWIP_SHA=ec55ae17618feeb57c8c10109bcf5c42723e8e95

MUSL_REPO=https://github.com/unikraft/lib-musl.git
MUSL_SHA=5fed64ecd7f8abb29df444c73df6d797d4efa18f

COMPILERRT_REPO=https://github.com/unikraft/lib-compiler-rt.git
COMPILERRT_SHA=61baeeb7ec4f88f0dd637bbbc52c9b459caa8d8d

clone_pinned() {
    local repo="$1" sha="$2" dest="$3"
    if [[ -d "$dest/.git" ]]; then
        echo "[skip clone] $dest already present"
        local current_url
        current_url="$(git -C "$dest" remote get-url origin 2>/dev/null || true)"
        if [[ -n "$current_url" && "$current_url" != "$repo" ]]; then
            echo "[remote]     origin -> $repo"
            git -C "$dest" remote set-url origin "$repo"
        fi
    else
        echo "[clone]      $repo -> $dest"
        git clone --quiet "$repo" "$dest"
    fi
    echo "[checkout]   $dest @ ${sha:0:10}"
    git -C "$dest" fetch --quiet origin "$sha" 2>/dev/null || true
    git -C "$dest" reset --quiet --hard
    git -C "$dest" clean --quiet -fdx
    git -C "$dest" checkout --quiet "$sha"
}

apply_patch() {
    local target="$1" patch="$2"
    # --reverse --check tells us if the patch is already applied (exit 0).
    if patch -d "$target" -p1 --dry-run --reverse --silent < "$patch" >/dev/null 2>&1; then
        echo "[skip patch] $(basename "$patch") already applied to $target"
        return 0
    fi
    echo "[patch]      $(basename "$patch") -> $target"
    patch -d "$target" -p1 --silent < "$patch"
}

cd "$ROOT"
mkdir -p libs

clone_pinned "$UNIKRAFT_REPO"   "$UNIKRAFT_SHA"   "$ROOT/unikraft"
clone_pinned "$LWIP_REPO"       "$LWIP_SHA"       "$ROOT/libs/lwip"
clone_pinned "$MUSL_REPO"       "$MUSL_SHA"       "$ROOT/libs/musl"
clone_pinned "$COMPILERRT_REPO" "$COMPILERRT_SHA" "$ROOT/libs/compiler-rt"

apply_patch "$ROOT/unikraft"  "$ROOT/patches/0001-unikraft-posix-tty-init-priority.patch"
apply_patch "$ROOT/libs/lwip" "$ROOT/patches/0002-lwip-rcvbuf-default.patch"

cat <<EOF

Setup complete. Next:

    cd apps/netperf
    cp netperf.defconfig .config
    make olddefconfig
    make -j\$(nproc)

The unikernel image will land at apps/netperf/build/netperf_qemu-x86_64.
See README.md for run / benchmark instructions.
EOF
