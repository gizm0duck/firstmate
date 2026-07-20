#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; passive harness adapters allow
# the stop on that signal, while Codex may reassert twice before failing open.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# The Codex reassertion counter bounds the continuation sequence and fails open
# after two reassertions until supervision is healthy or no work remains.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
CODEX_REASSERT_COUNTER="$STATE/.codex-turnend-reassertions"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

clear_codex_reassertions() {
  rm -f "$CODEX_REASSERT_COUNTER"
}

write_codex_reassertions() {  # <count>
  local count=$1 tmp
  [ ! -d "$CODEX_REASSERT_COUNTER" ] || return 1
  tmp="${CODEX_REASSERT_COUNTER}.tmp.$$"
  if printf '%s\n' "$count" > "$tmp" && mv -f "$tmp" "$CODEX_REASSERT_COUNTER"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || { clear_codex_reassertions; exit 0; }
fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && { clear_codex_reassertions; exit 0; }

# A bounded Codex checkpoint releases its foreground watcher lock before the
# forced continuation ends. Its old stop_hook_active bypass therefore let that
# continuation immediately end blind. Reassert up to the durable bound unless a
# real watcher is healthy; the fresh lock is the proof, not one checkpoint.
# Other harness adapters retain their one-follow-up loop guard because they use
# passive callbacks that cannot safely block recursively.
HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || true)
if [ "$STOP_HOOK_ACTIVE" = true ] && [ "$HARNESS" != codex ]; then
  exit 0
fi

if [ "$HARNESS" = codex ] && [ "$STOP_HOOK_ACTIVE" = true ]; then
  codex_reassertions=$(cat "$CODEX_REASSERT_COUNTER" 2>/dev/null || printf '0')
  case "$codex_reassertions" in ''|*[!0-9]*) codex_reassertions=0 ;; esac
  if [ "$codex_reassertions" -ge 2 ]; then
    echo 'WARNING: Codex supervision reassertion limit reached; allowing this stop without a live watcher lock.' >&2
    exit 0
  fi
  if ! write_codex_reassertions "$((codex_reassertions + 1))"; then
    echo 'WARNING: could not persist the Codex supervision reassertion counter; allowing this stop without a live watcher lock.' >&2
    exit 0
  fi
fi

afk=0
[ -e "$STATE/.afk" ] && afk=1
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
  || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
  printf '●  %s\n' "$REASON"
  printf '●%s\n' "$rule"
} >&2
exit 2
