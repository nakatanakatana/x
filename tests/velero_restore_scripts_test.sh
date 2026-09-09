#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FAKE_KUBECTL="$ROOT_DIR/tests/testdata/fake-kubectl-velero.sh"

assert_contains() {
  local needle="$1"
  local haystack_file="$2"
  if ! grep -Fq -- "$needle" "$haystack_file"; then
    printf 'expected %q in %s\n' "$needle" "$haystack_file" >&2
    exit 1
  fi
}

run_restore_script() {
  local log_file="$1"
  local delete_log="$2"
  shift 2
  PATH="$tmp_dir:$PATH" \
    FAKE_KUBECTL_APPLY_LOG="$log_file" \
    FAKE_KUBECTL_DELETE_LOG="$delete_log" \
    bash "$ROOT_DIR/scripts/velero-restore-pvc.sh" \
      backup-20260909 app source-pvc restored-pvc "$@"
}

run_restore_script_with_args() {
  local log_file="$1"
  local delete_log="$2"
  shift 2
  PATH="$tmp_dir:$PATH" \
    FAKE_KUBECTL_APPLY_LOG="$log_file" \
    FAKE_KUBECTL_DELETE_LOG="$delete_log" \
    bash "$ROOT_DIR/scripts/velero-restore-pvc.sh" "$@"
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

cp "$FAKE_KUBECTL" "$tmp_dir/kubectl"
chmod +x "$tmp_dir/kubectl"

apply_log="$tmp_dir/apply.log"
delete_log="$tmp_dir/delete.log"
touch "$apply_log" "$delete_log"

run_restore_script "$apply_log" "$delete_log" >/dev/null
assert_contains 'labelSelector:' "$apply_log"
assert_contains 'backup.pcloud.io/restore-id: "feed-reader-feed-reader-data"' "$apply_log"

: > "$apply_log"
: > "$delete_log"
if FAKE_FAIL_RESTORE_APPLY=1 run_restore_script "$apply_log" "$delete_log" >/dev/null 2>&1; then
  printf 'restore script unexpectedly succeeded when Restore creation failed\n' >&2
  exit 1
fi
assert_contains 'delete configmap' "$delete_log"

: > "$apply_log"
: > "$delete_log"
FAKE_SOURCE_PVC_MISSING=1 run_restore_script_with_args \
  "$apply_log" "$delete_log" \
  --restore-id feed-reader-feed-reader-data \
  backup-20260909 app source-pvc restored-pvc >/dev/null
assert_contains 'backup.pcloud.io/restore-id: "feed-reader-feed-reader-data"' "$apply_log"

test -f "$ROOT_DIR/scripts/velero-restore-vcluster-pvc.sh"
assert_contains 'vcluster.loft.sh/managed-by' "$ROOT_DIR/scripts/velero-restore-vcluster-pvc.sh"
assert_contains 'kind: Job' "$ROOT_DIR/scripts/velero-restore-vcluster-pvc.sh"

printf 'velero restore script tests passed\n'
