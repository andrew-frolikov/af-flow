#!/bin/bash
# Observe every outbound connection a command makes, and name the hosts.
#
# Written 2026-07-20 because de-risk checklist item 7 wants the destination
# hosts of a model download observed, and LuLu turned out to be the wrong
# instrument for it three times running.
#
# Why LuLu could never answer this. LuLu writes ONE rule per process, and the
# rule Andrew has for AF Flow is `any address:any port`. A process-scoped rule
# records no hostname, so there is nothing to read out, and searching LuLu for
# "huggingface" will always return nothing because LuLu indexes rules by
# process rather than by destination. LuLu is a good firewall and a bad
# evidence source for this particular question.
#
# What this does instead: samples the live socket table while the command runs,
# collects every distinct remote endpoint, and reverse-resolves each one. That
# is strictly better evidence than a firewall rule, because it is the actual
# observed traffic with timestamps, and it is reproducible on demand.
#
# Usage:
#   scripts/observe-egress.sh <process-name-pattern> -- <command...>
#
# Example:
#   scripts/observe-egress.sh GhostPepper -- xcodebuild test-without-building ...

set -uo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <process-name-pattern> -- <command...>" >&2
    exit 2
fi

PATTERN="$1"
shift
if [ "$1" != "--" ]; then
    echo "expected -- before the command" >&2
    exit 2
fi
shift

OUT_DIR="${EGRESS_OUT_DIR:-build/egress}"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
RAW="$OUT_DIR/egress-$STAMP.raw"
REPORT="$OUT_DIR/egress-$STAMP.md"

: > "$RAW"

# Self-test, because this project's rule is that a checker with logic of its own
# needs its own test in the same command. A monitor reporting "no connections"
# is an innocence claim, and an innocence claim from a broken monitor is the
# worst output this script could produce. So prove the sampler can see a known
# connection before trusting it about an unknown one.
#
# The canary has TWO stages, and the second exists because the first one lied.
#
# Stage 1 curls a host and checks the sampler sees it. That passed while the
# script was simultaneously reporting "no outbound connections" during a
# demonstrable 954 MB download. It proved only that the sampler can see its own
# child process, which is the easy case and not the case that matters. That is
# precisely the failure LOOP.md warns about: a canary proves a gate catches what
# its author imagined.
#
# Stage 2 is the one with teeth. `lsof` run from a sandboxed shell CANNOT see
# the socket table of a sandboxed application: measured 2026-07-20, five model
# downloads totalling over 3 GB, across which GhostPepper never appeared once in
# the full ESTABLISHED table while Chrome, Claude and Wispr Flow all did. So the
# script now refuses to run unless it can prove it can see the target itself.
CANARY_SEEN=0
( curl -s -m 8 -o /dev/null https://example.com 2>/dev/null ) &
CANARY_PID=$!
for _ in $(seq 1 40); do
    if lsof +c 0 -i -nP 2>/dev/null | grep -q "^curl"; then
        CANARY_SEEN=1
        break
    fi
    sleep 0.2
done
wait $CANARY_PID 2>/dev/null

if [ "$CANARY_SEEN" -ne 1 ]; then
    echo "SELF-TEST FAILED: the sampler cannot observe even its own child's connection." >&2
    exit 3
fi

if ! pgrep -f "$PATTERN" >/dev/null 2>&1; then
    echo "NOTE: no process matching '$PATTERN' is running yet; visibility will be" >&2
    echo "      checked against the first sample instead." >&2
elif ! lsof +c 0 -i -nP 2>/dev/null | grep -qiE "$PATTERN"; then
    cat >&2 <<'WARNING'
SELF-TEST WARNING: a process matching the pattern is running, but lsof reports
no network descriptors for it at all. If the target is a sandboxed app, this
tool is BLIND to it and any "no outbound connections" result it produces is
meaningless rather than reassuring. Use a network-extension firewall (LuLu) or
an offline test instead. See PROGRESS.md, 2026-07-20.
WARNING
fi
echo "self-test ok: sampler observed a known connection"

echo "observing connections from processes matching '$PATTERN'"
echo "raw samples: $RAW"
echo

# Sample in the background. 0.3s is fast enough to catch a TCP handshake that
# completes quickly, without the sampler itself becoming the load.
# `+c 0` is load-bearing, not a flourish. lsof truncates the COMMAND column to
# NINE characters by default, so "GhostPepper" is rendered "GhostPepp" and a
# grep for the real process name silently matches nothing. The first version of
# this script omitted it and reported "no outbound connections observed" while
# 954 MB of model was demonstrably coming down the wire. A monitor that cannot
# see is worse than no monitor, because it manufactures evidence of innocence.
(
    while :; do
        lsof +c 0 -i -nP 2>/dev/null \
            | grep -iE "$PATTERN" \
            | grep -E "TCP|UDP" \
            >> "$RAW"
        sleep 0.3
    done
) &
SAMPLER=$!
# shellcheck disable=SC2064
trap "kill $SAMPLER 2>/dev/null" EXIT

START=$(date +%s)
"$@"
STATUS=$?
END=$(date +%s)

kill $SAMPLER 2>/dev/null
trap - EXIT

echo
echo "command exited $STATUS after $((END - START))s"
echo

# Extract remote endpoints. lsof renders them as local->remote; the remote side
# is what matters, and ESTABLISHED/SYN_SENT both count because an attempt is as
# interesting as a completed connection.
REMOTES=$(grep -oE '\->[0-9a-fA-F:.]+:[0-9]+' "$RAW" \
    | sed 's/^->//' \
    | sort -u)

{
    echo "# Egress observation, $STAMP"
    echo
    echo "Command: \`$*\`"
    echo
    echo "Process pattern: \`$PATTERN\`  |  Duration: $((END - START))s  |  Exit: $STATUS"
    echo
    if [ -z "$REMOTES" ]; then
        echo "## No outbound connections observed"
        echo
        echo "The socket table was sampled every 0.3s for the whole run and no"
        echo "remote endpoint ever appeared for a matching process."
    else
        echo "## Remote endpoints observed"
        echo
        echo "| Address | Port | Reverse DNS |"
        echo "|---|---|---|"
        while IFS= read -r endpoint; do
            [ -z "$endpoint" ] && continue
            addr="${endpoint%:*}"
            port="${endpoint##*:}"
            host=$(dig +short -x "$addr" 2>/dev/null | head -1)
            [ -z "$host" ] && host="(no PTR record)"
            echo "| $addr | $port | $host |"
        done <<< "$REMOTES"
    fi
} > "$REPORT"

cat "$REPORT"
echo
echo "report: $REPORT"
exit $STATUS
