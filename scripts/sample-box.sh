#!/usr/bin/env bash
#
# Whole-box sampler for a task-cost measurement run (issue #906).
#
# Protocol: docs/develop/measuring-task-cost.md
#
# Run by the COORDINATOR, not by a measuring agent. An agent can see only its
# own processes; at N>1 the numbers that matter -- total memory across every
# agent, machine-wide I/O pressure, link-pool queue depth, disk growth -- have
# no per-agent view at all. `/usr/bin/time -v`'s max RSS is the largest single
# process, never a sum, which is exactly the gap this fills.
#
# Emits one epoch-stamped line per interval so samples correlate with the UTC
# timestamps agents record per gate.
#
# Usage: sample-box.sh [--interval SECONDS] [--out FILE] [--label TEXT]
#
# Reads only /proc and runs only ps/df. It starts no build, holds no link slot
# and writes nothing outside --out, so it does not perturb what it measures.

set -u

interval=5
out="box-samples.tsv"
label=""

while [ $# -gt 0 ]; do
    case "$1" in
        --interval) interval="${2:?--interval needs a value}"; shift 2 ;;
        --out)      out="${2:?--out needs a value}"; shift 2 ;;
        --label)    label="${2:?--label needs a value}"; shift 2 ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "sample-box.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$interval" in
    ''|*[!0-9]*) echo "sample-box.sh: --interval must be a positive integer" >&2; exit 2 ;;
    0) echo "sample-box.sh: --interval must be greater than 0" >&2; exit 2 ;;
esac

# The link pool build-gate.sh uses. Occupancy is counted as slot files held,
# which is what makes queue depth (linkers minus slots) meaningful.
pool="${DAD_BUILD_GATE_DIR:-/tmp/dad-build-gate-$(id -u)}/link"

# $1 = cpu|io|memory, $2 = some|full -> avg10 as a bare number.
# The lines read `some avg10=... avg60=...` with NO trailing colon on the
# first field; matching "some:" silently yields an empty column, which is how
# the first version of this script produced blank PSI for every sample.
psi() {
    local v
    v=$(awk -v want="$2" '$1 == want { for (i = 2; i <= NF; i++)
        if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i; exit } }' \
        "/proc/pressure/$1" 2>/dev/null)
    # `cpu full` is always 0 outside a cgroup, and older kernels omit the line
    # entirely; NA distinguishes "not reported" from a real zero.
    printf '%s' "${v:-NA}"
}

# Sum RSS in kB over every process whose comm matches the toolchain. This is
# the number no agent can report.
toolchain_rss_kb() {
    ps -eo comm=,rss= 2>/dev/null | awk '
        $1 == "rustc" || $1 == "cargo" || $1 == "ld" || $1 == "ld.lld" ||
        $1 == "collect2" || $1 == "cc1" || $1 == "cc1plus" || $1 == "mold" { s += $2 }
        END { print s + 0 }'
}

count() { pgrep -x "$1" 2>/dev/null | wc -l | tr -d ' '; }

if [ ! -e "$out" ]; then
    printf 'epoch\tiso\tlabel\tload1\tmemavail_kB\ttoolchain_rss_kB\tld\trustc\tcargo\tslots_held\tslots_total\tqueue_depth\tcpu_some\tio_some\tio_full\tmem_some\tdisk_avail_kB\n' > "$out"
fi

have_fuser=no
if command -v fuser >/dev/null 2>&1; then
    have_fuser=yes
else
    echo "sample-box.sh: WARNING: fuser not found — slots_held will read 0 and" >&2
    echo "  queue_depth will be meaningless. Install psmisc, or ignore those two" >&2
    echo "  columns; every other column is unaffected." >&2
fi

echo "sample-box.sh: sampling every ${interval}s into $out (Ctrl-C to stop)" >&2

trap 'echo "sample-box.sh: stopped" >&2; exit 0' INT TERM

while :; do
    epoch=$(date -u +%s)
    iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo NA)
    memavail=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo NA)
    rss=$(toolchain_rss_kb)
    nld=$(count ld); nrustc=$(count rustc); ncargo=$(count cargo)

    slots_total=0; slots_held=0
    if [ -d "$pool" ]; then
        for slot in "$pool"/slot.*; do
            [ -e "$slot" ] || continue
            slots_total=$((slots_total + 1))
            # A held slot is one some process has open. flock(2) locks are
            # released by the kernel on exit, so an fd here means a live holder.
            if [ "$have_fuser" = yes ] && fuser "$slot" >/dev/null 2>&1; then
                slots_held=$((slots_held + 1))
            fi
        done
    fi

    # Linkers beyond the slots they can hold are queued. Approximate: ld and
    # collect2 nest, so treat this as indicative, not exact.
    queue=$((nld - slots_held)); [ "$queue" -lt 0 ] && queue=0

    disk=$(df -Pk . 2>/dev/null | awk 'NR==2{print $4}' || echo NA)

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$epoch" "$iso" "${label:-none}" "$load1" "$memavail" "$rss" \
        "$nld" "$nrustc" "$ncargo" "$slots_held" "$slots_total" "$queue" \
        "$(psi cpu some)" "$(psi io some)" "$(psi io full)" "$(psi memory some)" \
        "$disk" >> "$out"

    sleep "$interval"
done
