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
