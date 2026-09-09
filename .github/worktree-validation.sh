#!/usr/bin/env bash
set -euo pipefail
: "${VALIDATION_EVIDENCE:?}"
: "${PROVIDER:?}"
export CARGO_TARGET_DIR=target
cmp scripts/link-gate.sh "$GITHUB_WORKSPACE/scripts/link-gate.sh"
cmp scripts/build-gate.sh "$GITHUB_WORKSPACE/scripts/build-gate.sh"
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$GITHUB_WORKSPACE/scripts/link-gate.sh"
test ! -e "$CARGO_TARGET_DIR"
mkdir -p "$VALIDATION_EVIDENCE"
measure() {
    name=$1
    shift
    /usr/bin/time -f 'wall_seconds=%e\nmax_rss_kib=%M\nexit_status=%x' \
        -o "$VALIDATION_EVIDENCE/$name-time.txt" \
        "$@" 2>&1 | tee "$VALIDATION_EVIDENCE/$name.log"
    if [ "$PROVIDER" = BoringCache ]; then
        sccache --show-stats --stats-format=json > "$VALIDATION_EVIDENCE/sccache-after-$name.json"
    fi
}
measure fmt cargo fmt --check
measure clippy cargo clippy --workspace --all-targets --features e2e,e2e-live -- -D warnings
measure test-fast cargo test-fast
measure linkage-check cargo xtask linkage-check
du -sk "$CARGO_TARGET_DIR" > "$VALIDATION_EVIDENCE/target-kib.txt"
find "$CARGO_TARGET_DIR" -type f | wc -l > "$VALIDATION_EVIDENCE/target-files.txt"
