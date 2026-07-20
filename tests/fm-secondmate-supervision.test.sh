#!/usr/bin/env bash
# Hermetic coverage for the secondmate home-beacon probe and routing deadline.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-supervision)
export FM_SECONDMATE_SUPERVISION_GRACE=1
export FM_SECONDMATE_SUPERVISION_CONFIRM_SECS=0
export FM_SECONDMATE_DEADLINE_SECS=1
export FM_HOME="$TMP_ROOT/parent"
mkdir -p "$FM_HOME/state"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

FM_WAKE_LOG=
fm_backend_target_exists() { case "$2" in dead:*) return 1 ;; *) return 0 ;; esac; }
fm_wake_append() { printf '%s\n' "$3" >> "$FM_WAKE_LOG"; }
wake() { return 0; }

make_fixture() {  # <name> <child-status-or-empty> <live-child 0|1>
  local name=$1 child_status=$2 live=$3 parent home
  parent="$TMP_ROOT/$name/parent"
  home="$TMP_ROOT/$name/mate"
  mkdir -p "$parent/state" "$home/state"
  fm_write_secondmate_meta "$parent/state/mate.meta" "$home" 'parent:fm-mate'
  if [ "$live" = 0 ]; then
    fm_write_meta "$home/state/child.meta" 'window=dead:fm-child' 'backend=tmux' 'kind=crew'
  else
    fm_write_meta "$home/state/child.meta" 'window=child:fm-child' 'backend=tmux' 'kind=crew'
  fi
  [ -n "$child_status" ] && printf '%s\n' "$child_status" > "$home/state/child.status"
  STATE="$parent/state"
  FM_WAKE_LOG="$parent/wakes"
  : > "$FM_WAKE_LOG"
  printf '%s\n' "$parent:$home"
}

run_probe() {
  secondmate_supervision_scan >/dev/null 2>&1 || true
}

activate_fixture() {  # <parent-home>
  STATE="$1/state"
  FM_HOME=$1
  DATA="$FM_HOME/data"
  FM_WAKE_LOG="$1/wakes"
}

test_invalid_deadline_setting_falls_back_to_default() {
  local out status
  out=$(ROOT="$ROOT" TMP_ROOT="$TMP_ROOT" FM_SECONDMATE_DEADLINE_SECS=oops bash -c '
    export FM_HOME="$TMP_ROOT/invalid-deadline"
    mkdir -p "$FM_HOME/state"
    . "$ROOT/bin/fm-watch.sh"
    [ "$SECONDMATE_DEADLINE_SECS" = 900 ]
  ' 2>&1)
  status=$?
  expect_code 0 "$status" "invalid secondmate deadline setting must fall back before watcher arithmetic"
  [ -z "$out" ] || fail "invalid secondmate deadline fallback printed output: $out"
  pass "secondmate supervision: invalid deadline setting falls back to 900"
}

test_fresh_beacon_with_inflight_child_is_silent() {
  local paths parent home
  paths=$(make_fixture fresh 'working: active' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  touch "$home/state/.last-watcher-beat"
  run_probe
  [ ! -s "$parent/wakes" ] || fail "fresh beacon incorrectly alarmed: $(cat "$parent/wakes")"
  pass "secondmate supervision: fresh beacon with an in-flight child is silent"
}

test_stale_beacon_with_inflight_child_alarms() {
  local paths parent home
  paths=$(make_fixture stale 'working: active' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  run_probe
  assert_contains "$(cat "$parent/wakes")" 'supervision: mate has 1 child task(s) awaiting a wake' "stale live child did not alarm"
  pass "secondmate supervision: stale beacon with an in-flight child alarms"
}

test_stale_beacon_without_awaiting_children_is_silent() {
  local paths parent home
  paths=$(make_fixture idle 'done: complete' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  touch -t 201901010000 "$home/state/child.status"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  run_probe
  [ ! -s "$parent/wakes" ] || fail "terminal child incorrectly alarmed"
  pass "secondmate supervision: stale idle home is healthy"
}

test_finished_child_with_stale_parent_alarms() {
  local paths parent home
  paths=$(make_fixture finished 'done: child report is ready' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  touch "$home/state/child.status"
  run_probe
  assert_contains "$(cat "$parent/wakes")" 'supervision: mate has 1 child task(s) awaiting a wake' "new done child did not alarm a stale parent"
  pass "secondmate supervision: a completion after the stale beacon alarms"
}

test_any_new_child_event_with_stale_parent_alarms() {
  local status paths parent home
  for status in 'blocked: waiting for a fix' 'needs-decision: choose an option' 'failed: command failed' 'paused: upstream wait'; do
    paths=$(make_fixture "event-${status%%:*}" "$status" 1); parent=${paths%%:*}; home=${paths#*:}
    activate_fixture "$parent"
    touch -t 202501010101 "$home/state/.last-watcher-beat"
    touch -t 202501010101 "$home/state/child.status"
    run_probe
    assert_contains "$(cat "$parent/wakes")" 'supervision: mate has 1 child task(s) awaiting a wake' "new $status event did not alarm a stale parent"
  done
  pass "secondmate supervision: any event at or after the stale beacon alarms"
}

test_parked_and_dead_children_are_silent() {
  local paths parent home
  paths=$(make_fixture parked 'needs-decision: captain input' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  touch -t 201901010000 "$home/state/child.status"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  run_probe
  [ ! -s "$parent/wakes" ] || fail "parked needs-decision child incorrectly alarmed"
  paths=$(make_fixture held 'captain-held: awaiting captain response' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  touch -t 201901010000 "$home/state/child.status"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  run_probe
  [ ! -s "$parent/wakes" ] || fail "captain-held child incorrectly alarmed"
  paths=$(make_fixture dead 'blocked: stale dead endpoint' 0); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  run_probe
  [ ! -s "$parent/wakes" ] || fail "dead leftover child incorrectly alarmed"
  pass "secondmate supervision: parked and dead leftover children are silent"
}

test_legacy_secondmate_home_backfill_alarms() {
  local paths parent home
  paths=$(make_fixture legacy 'working: active' 1); parent=${paths%%:*}; home=${paths#*:}
  sed -i.bak '/^home=/d' "$parent/state/mate.meta"
  rm -f "$parent/state/mate.meta.bak"
  mkdir -p "$parent/data"
  printf '%s\n' "- mate - fixture (home: $home; scope: fixture; projects: sample; added 2026-07-20)" > "$parent/data/secondmates.md"
  activate_fixture "$parent"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  run_probe
  assert_contains "$(cat "$parent/wakes")" 'supervision: mate has 1 child task(s) awaiting a wake' "registry-backed secondmate home did not alarm"
  pass "secondmate supervision: legacy home metadata backfills from the registry"
}

test_deadline_arms_and_clears_on_terminal_status() {
  local paths parent home deadline signature
  paths=$(make_fixture deadline 'working: accepted' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  deadline="$parent/state/.secondmate-deadline-mate"
  signature=$(status_file_signature "$parent/state/mate.status")
  printf '1 %s\n' "$signature" > "$deadline"
  secondmate_deadline_scan >/dev/null 2>&1 || true
  assert_contains "$(cat "$parent/wakes")" 'deadline: secondmate mate' "expired routing deadline did not alarm"
  printf 'done: routed work complete\n' > "$parent/state/mate.status"
  secondmate_deadline_scan >/dev/null 2>&1 || true
  assert_absent "$deadline" "terminal secondmate status did not clear routing deadline"
  pass "secondmate supervision: routing deadline alarms and clears on terminal status"
}

test_deadline_does_not_clear_on_presend_terminal_status() {
  local paths parent home deadline signature
  paths=$(make_fixture presend-terminal 'working: accepted' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  deadline="$parent/state/.secondmate-deadline-mate"
  printf 'done: prior assignment complete\n' > "$parent/state/mate.status"
  signature=$(status_file_signature "$parent/state/mate.status")
  secondmate_deadline_write "$deadline" 1 "$signature"
  secondmate_deadline_scan >/dev/null 2>&1 || true
  assert_contains "$(cat "$parent/wakes")" 'deadline: secondmate mate' "pre-send terminal status silently cleared the routing deadline"
  [ -e "$deadline" ] || fail "pre-send terminal status removed the routing deadline"
  pass "secondmate supervision: prior terminal status does not clear a new deadline"
}

test_deadline_refreshes_on_status_activity() {
  local paths parent home deadline signature now expiry
  paths=$(make_fixture heartbeat 'working: accepted' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  deadline="$parent/state/.secondmate-deadline-mate"
  printf 'working: acknowledged\n' > "$parent/state/mate.status"
  signature=$(status_file_signature "$parent/state/mate.status")
  printf '1 %s\n' "$signature" > "$deadline"
  printf 'working: still progressing\n' >> "$parent/state/mate.status"
  now=$(date +%s)
  secondmate_deadline_scan >/dev/null 2>&1 || true
  [ ! -s "$parent/wakes" ] || fail "status activity incorrectly raised a deadline alarm"
  read -r expiry signature < "$deadline"
  [ "$expiry" -ge $((now + 1)) ] || fail "status activity did not refresh the routing deadline"
  pass "secondmate supervision: status activity refreshes the routing deadline"
}

test_deadline_write_failure_does_not_enqueue_alarm() {
  local paths parent home deadline signature errors
  paths=$(make_fixture deadline-write-failure 'working: accepted' 1); parent=${paths%%:*}; home=${paths#*:}
  activate_fixture "$parent"
  deadline="$parent/state/.secondmate-deadline-mate"
  signature=$(status_file_signature "$parent/state/mate.status")
  printf '1 %s\n' "$signature" > "$deadline"
  secondmate_deadline_write() { return 1; }
  errors="$parent/errors"
  secondmate_deadline_scan >/dev/null 2>"$errors" || true
  secondmate_deadline_scan >/dev/null 2>>"$errors" || true
  [ ! -s "$parent/wakes" ] || fail "deadline write failure queued an alarm: $(cat "$parent/wakes")"
  assert_contains "$(cat "$errors")" 'error: could not refresh secondmate deadline for mate' "deadline write failure was not surfaced"
  pass "secondmate supervision: deadline write failure does not enqueue an alarm"
}

test_invalid_deadline_setting_falls_back_to_default
test_fresh_beacon_with_inflight_child_is_silent
test_stale_beacon_with_inflight_child_alarms
test_stale_beacon_without_awaiting_children_is_silent
test_finished_child_with_stale_parent_alarms
test_any_new_child_event_with_stale_parent_alarms
test_parked_and_dead_children_are_silent
test_legacy_secondmate_home_backfill_alarms
test_deadline_arms_and_clears_on_terminal_status
test_deadline_does_not_clear_on_presend_terminal_status
test_deadline_refreshes_on_status_activity
test_deadline_write_failure_does_not_enqueue_alarm
