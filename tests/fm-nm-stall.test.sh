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
  FM_NM_STALL_ACTIVE_SECS=900 nm_stall_check_task task "$dir/state"
  out=$NM_STALL_DETAIL
  [ -z "$out" ] || fail "the first active observation must establish a baseline"
  FM_NM_STALL_ACTIVE_SECS=900 nm_stall_check_task task "$dir/state"
  out=$NM_STALL_DETAIL
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
  FM_NM_STALL_PARKED_SECS=480 nm_stall_check_task task "$dir/state"
  out=$NM_STALL_DETAIL
  [ -z "$out" ] || fail "the first parked observation must establish a baseline"
  FM_NM_STALL_PARKED_SECS=480 nm_stall_check_task task "$dir/state"
  out=$NM_STALL_DETAIL
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
  nm_stall_check_task task "$dir/state"
  FM_FAKE_SNAPSHOT=$'run-silent\treview\trunning\t1'
  export FM_FAKE_SNAPSHOT
  nm_stall_check_task task "$dir/state"
  out=$NM_STALL_DETAIL
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
  nm_stall_check_task task "$dir/state"
  FM_NM_STALL_ACTIVE_SECS=900 nm_stall_check_task task "$dir/state"
  out=$NM_STALL_DETAIL
  [ -z "$out" ] || fail "healthy active run incorrectly tripped: $out"
  pass "no-mistakes stall detector: healthy active run stays quiet"
}

test_elapsed_duration_is_not_a_silent_advance() {
  local dir out
  dir=$(new_case elapsed)
  FM_FAKE_SNAPSHOT=$'run-elapsed\treview\trunning\t10'
  export FM_FAKE_SNAPSHOT
  nm_stall_check_task task "$dir/state"
  FM_FAKE_SNAPSHOT=$'run-elapsed\treview\trunning\t11'
  export FM_FAKE_SNAPSHOT
  nm_stall_check_task task "$dir/state"
  out=$NM_STALL_DETAIL
  [ -z "$out" ] || fail "elapsed duration alone incorrectly tripped a silent advance: $out"
  pass "no-mistakes stall detector: elapsed duration is not a run advance"
}

test_zero_duration_uses_first_seen_age() {
  local dir out marker
  dir=$(new_case zero-duration)
  touch -t 202001010000 "$dir/state/task.status"
  FM_FAKE_SNAPSHOT=$'run-zero\tpipeline\tfixing\t0'
  export FM_FAKE_SNAPSHOT
  nm_stall_check_task task "$dir/state"
  marker="$dir/state/.nm-stall-task"
  printf '%s\n%s\n\n%s\n' $'run-zero\tpipeline\tfixing' "$(_fm_nm_stall_status_signature "$dir/state/task.status")" "$(( $(date +%s) - 901 ))" > "$marker"
  nm_stall_check_task task "$dir/state"
  out=$NM_STALL_DETAIL
  case "$out" in
    *"run run-zero step pipeline task task"*) : ;;
    *) fail "zero-duration fixing run did not age from its first observation: $out" ;;
  esac
  pass "no-mistakes stall detector: zero-duration run uses first-seen age"
}

test_alert_is_committed_after_queue_success() {
  local dir out
  dir=$(new_case post-queue)
  touch -t 202001010000 "$dir/state/task.status"
  FM_FAKE_SNAPSHOT=$'run-queue\treview\trunning\t901'
  export FM_FAKE_SNAPSHOT
  nm_stall_check_task task "$dir/state"
  nm_stall_check_task task "$dir/state"
  out=$NM_STALL_DETAIL
  [ -n "$out" ] || fail "stalled run did not produce a pending alert"
  [ "$(sed -n '3p' "$dir/state/.nm-stall-task")" != stalled ] || fail "alert was committed before queue success"
  nm_stall_commit_alert task "$dir/state" "$NM_STALL_SNAPSHOT" "$NM_STALL_SIG" "$NM_STALL_ALERT" "$NM_STALL_SEEN"
  nm_stall_check_task task "$dir/state"
  [ -z "$NM_STALL_DETAIL" ] || fail "committed alert was not suppressed"
  pass "no-mistakes stall detector: alert commits only after queue success"
}

test_active_step_stall
test_parked_gate_stall
test_silent_advance
test_healthy_active_run
test_elapsed_duration_is_not_a_silent_advance
test_zero_duration_uses_first_seen_age
test_alert_is_committed_after_queue_success

echo "# fm-nm-stall.test.sh: all assertions passed"
