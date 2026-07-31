#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/setup-kvm-agent.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

awk '
  /<<'\''JOB_HELPER'\''$/ {
    capture = 1
    next
  }
  capture && /^JOB_HELPER$/ {
    exit
  }
  capture
' "$SETUP_SCRIPT" > "$TEMP_DIR/kvm-agent-swarm-job"
chmod 0755 "$TEMP_DIR/kvm-agent-swarm-job"
bash -n "$TEMP_DIR/kvm-agent-swarm-job"

mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/manager" "$TEMP_DIR/worker/jobs"
export MOCK_WORKER_HOME="$TEMP_DIR/worker"

cat > "$TEMP_DIR/bin/kvm-agent-swarm-ssh" <<'MOCK_SSH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == bash && "${2:-}" == -s && "${3:-}" == -- ]] || {
  echo "Unsupported mocked SSH invocation: $*" >&2
  exit 2
}
shift 3
HOME="$MOCK_WORKER_HOME" bash -s -- "$@"
MOCK_SSH
chmod 0755 "$TEMP_DIR/bin/kvm-agent-swarm-ssh"

cat > "$TEMP_DIR/bin/kvm-agent-swarm-rsync" <<'MOCK_RSYNC'
#!/usr/bin/env bash
set -Eeuo pipefail
translated=()
for argument in "$@"; do
  case "$argument" in
    kvm-agent-worker:*)
      remote_path="${argument#kvm-agent-worker:}"
      translated+=("$MOCK_WORKER_HOME/$remote_path")
      ;;
    *) translated+=("$argument") ;;
  esac
done
exec /usr/bin/rsync "${translated[@]}"
MOCK_RSYNC
chmod 0755 "$TEMP_DIR/bin/kvm-agent-swarm-rsync"

export PATH="$TEMP_DIR/bin:$PATH"
export HOME="$TEMP_DIR/manager"

mkdir -p "$TEMP_DIR/experiment"
cat > "$TEMP_DIR/experiment/run-experiment.sh" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
echo started
echo result > result.txt
echo completed
RUNNER
chmod 0755 "$TEMP_DIR/experiment/run-experiment.sh"

job_id="$($TEMP_DIR/kvm-agent-swarm-job submit "$TEMP_DIR/experiment" \
  --timeout 10 -- ./run-experiment.sh)"
[[ "$job_id" =~ ^job- ]] || fail "submit did not return a job id: $job_id"

status=""
for _ in $(seq 1 50); do
  status="$($TEMP_DIR/kvm-agent-swarm-job status "$job_id")"
  [[ "$status" == FINISHED\ * ]] && break
  sleep 0.05
done
[[ "$status" == "FINISHED 0" ]] || fail "unexpected completed status: $status"

log="$($TEMP_DIR/kvm-agent-swarm-job log "$job_id" 20)"
grep -Fq 'completed' <<< "$log" || fail "job log does not contain runner output"

mkdir -p "$TEMP_DIR/fetched"
"$TEMP_DIR/kvm-agent-swarm-job" fetch "$job_id" "$TEMP_DIR/fetched"
[[ "$(cat "$TEMP_DIR/fetched/result.txt")" == result ]] || fail \
  "fetched job result is missing or incorrect"

listed="$($TEMP_DIR/kvm-agent-swarm-job list)"
grep -Fxq "$job_id" <<< "$listed" || fail "completed job is absent from list"

mkdir -p "$TEMP_DIR/slow-experiment"
cat > "$TEMP_DIR/slow-experiment/run-experiment.sh" <<'SLOW_RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
echo sleeping
sleep 20
SLOW_RUNNER
chmod 0755 "$TEMP_DIR/slow-experiment/run-experiment.sh"

slow_job="$($TEMP_DIR/kvm-agent-swarm-job submit "$TEMP_DIR/slow-experiment" \
  --timeout 30 -- ./run-experiment.sh)"
for _ in $(seq 1 20); do
  status="$($TEMP_DIR/kvm-agent-swarm-job status "$slow_job")"
  [[ "$status" == RUNNING ]] && break
  sleep 0.05
done
[[ "$status" == RUNNING ]] || fail "slow job never entered RUNNING state: $status"

cancelled="$($TEMP_DIR/kvm-agent-swarm-job cancel "$slow_job")"
[[ "$cancelled" == CANCELLED ]] || fail "cancel did not report success: $cancelled"
[[ "$($TEMP_DIR/kvm-agent-swarm-job status "$slow_job")" == "FINISHED 130" ]] || fail \
  "cancelled job did not record exit status 130"

echo "Mocked swarm job workflow passed."
