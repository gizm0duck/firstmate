#!/usr/bin/env bash
# Watcher-side no-mistakes stall classification tests.
#
# The detector consumes the attributed run snapshot owned by fm-crew-state.sh,
# then keeps its markers in the owning state home.
# These synthetic cases pin active-step stalls, parked-gate stalls, silent run
# advancement without a status write, and the healthy active control.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-stall)
mkdir -p "$TMP_ROOT"
FAKE_CREW_STATE="$TMP_ROOT/fm-crew-state.sh"
cat > "$FAKE_CREW_STATE" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --stall-snapshot ] || exit 2
printf '%s\n' "${FM_FAKE_SNAPSHOT:-}"
SH
chmod +x "$FAKE_CREW_STATE"

export FM_CREW_STATE_BIN="$FAKE_CREW_STATE"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf 'working: validation started\n' > "$dir/state/task.status"
  printf '%s\n' "$dir"
}

test_active_step_stall() {
  local dir out
  dir=$(new_case active)
  touch -t 202001010000 "$dir/state/task.status"
  FM_FAKE_SNAPSHOT=$'run-active\treview\trunning\t901'
  export FM_FAKE_SNAPSHOT
  out=$(FM_NM_STALL_ACTIVE_SECS=900 nm_stall_check_task task "$dir/state")
  [ -z "$out" ] || fail "the first active observation must establish a baseline"
  out=$(FM_NM_STALL_ACTIVE_SECS=900 nm_stall_check_task task "$dir/state")
  case "$out" in
    *"run run-active step review task task"*) : ;;
    *) fail "stuck running step did not trip with run, step, and task: $out" ;;
  esac
  pass "no-mistakes stall detector: stuck running step wakes once with run, step, and task"
}

test_parked_gate_stall() {
  local dir out
  dir=$(new_case parked)
  touch -t 202001010000 "$dir/state/task.status"
  FM_FAKE_SNAPSHOT=$'run-parked\treview\tawaiting_approval\t481'
  export FM_FAKE_SNAPSHOT
  out=$(FM_NM_STALL_PARKED_SECS=480 nm_stall_check_task task "$dir/state")
  [ -z "$out" ] || fail "the first parked observation must establish a baseline"
  out=$(FM_NM_STALL_PARKED_SECS=480 nm_stall_check_task task "$dir/state")
  case "$out" in
    *"run run-parked step review task task"*) : ;;
    *) fail "parked awaiting-approval gate did not trip: $out" ;;
  esac
  pass "no-mistakes stall detector: parked gate wakes after its shorter threshold"
}

test_silent_advance() {
  local dir out
  dir=$(new_case silent)
  FM_FAKE_SNAPSHOT=$'run-silent\tintent\trunning\t10'
  export FM_FAKE_SNAPSHOT
  nm_stall_check_task task "$dir/state" >/dev/null
  FM_FAKE_SNAPSHOT=$'run-silent\treview\trunning\t1'
  export FM_FAKE_SNAPSHOT
  out=$(nm_stall_check_task task "$dir/state")
  case "$out" in
    *"silent advance"*"run run-silent step review task task"*) : ;;
    *) fail "run advance without status write did not trip: $out" ;;
  esac
  pass "no-mistakes stall detector: silent run advancement wakes immediately"
}

test_healthy_active_run() {
  local dir out
  dir=$(new_case healthy)
  FM_FAKE_SNAPSHOT=$'run-healthy\treview\trunning\t12'
  export FM_FAKE_SNAPSHOT
  nm_stall_check_task task "$dir/state" >/dev/null
  out=$(FM_NM_STALL_ACTIVE_SECS=900 nm_stall_check_task task "$dir/state")
  [ -z "$out" ] || fail "healthy active run incorrectly tripped: $out"
  pass "no-mistakes stall detector: healthy active run stays quiet"
}

test_active_step_stall
test_parked_gate_stall
test_silent_advance
test_healthy_active_run

echo "# fm-nm-stall.test.sh: all assertions passed"
