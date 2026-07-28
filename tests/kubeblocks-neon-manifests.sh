#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_file_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq -- "$expected" "$file"; then
    printf 'missing expected content in %s: %s\n' "$file" "$expected" >&2
    exit 1
  fi
}

assert_file_absent() {
  local file="$1"
  if [[ -e "$file" ]]; then
    printf 'obsolete file still exists: %s\n' "$file" >&2
    exit 1
  fi
}

assert_file_contains \
  "$repo_root/clusters/home/_system/namespaces/kb-system.yaml" \
  "name: kb-system"
assert_file_contains \
  "$repo_root/clusters/home/_system/namespaces/database.yaml" \
  "name: database"
assert_file_contains \
  "$repo_root/clusters/home/controllers/kubeblocks.yaml" \
  'path: "components/kubeblocks"'
assert_file_contains \
  "$repo_root/clusters/home/controllers/kubeblocks.yaml" \
  "wait: true"
assert_file_contains \
  "$repo_root/clusters/home/controllers/_next.yaml" \
  "name: cluster-controllers"
assert_file_contains \
  "$repo_root/clusters/home/resources/_next.yaml" \
  "name: cluster-resources"

assert_file_absent "$repo_root/clusters/home/_system/namespaces/postgres-operator.yaml"
assert_file_absent "$repo_root/clusters/home/controllers/postgres-operator.yaml"
assert_file_absent "$repo_root/components/postgres-operator"

# File absence is the behavior under test here: these files were direct
# Flux entry points, so retaining any one of them keeps the old operator live.
if rg -n 'postgres-operator|opensource\.zalando\.com' \
  "$repo_root/components" "$repo_root/clusters/home"; then
  printf '%s\n' 'obsolete Postgres Operator reference remains' >&2
  exit 1
fi

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
kustomize build "$repo_root/components/kubeblocks" >"$rendered"

for expected in \
  "name: kubeblocks" \
  "chart: kubeblocks" \
  'version: 1.0.0' \
  "name: neon" \
  "chart: neon" \
  'version: 1.0.1' \
  "dependsOn:" \
  "name: kubeblocks" \
  "kind: ComponentDefinition" \
  "name: neon-pageserver" \
  "name: neon-s3-credentials" \
  "AWS_ACCESS_KEY_ID" \
  "AWS_SECRET_ACCESS_KEY" \
  "remote_storage" \
  "bucket_name='neon-demo'" \
  "bucket_region='us-east-1'" \
  "endpoint='http://gateway.pcloud-s3.svc.cluster.local:8080'" \
  "RCLONE_CONFIG_NEON_FORCE_PATH_STYLE" \
  "rclone/rclone:1.74.4@sha256:c61954aaa32328a5486715dd063a81c7879f5195ad3505cd362deddd509dc4a1"
do
  if ! grep -Fq -- "$expected" "$rendered"; then
    printf 'missing rendered KubeBlocks content: %s\n' "$expected" >&2
    exit 1
  fi
done

if grep -Eq 'image:[[:space:]]*[^[:space:]]*:latest[[:space:]]*$' "$rendered"; then
  printf '%s\n' 'unpinned latest image remains in rendered KubeBlocks content' >&2
  exit 1
fi

if grep -Fq -- "WipeOut" "$rendered"; then
  printf '%s\n' 'destructive WipeOut policy remains in rendered KubeBlocks content' >&2
  exit 1
fi
