#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
controller_rendered="$(mktemp)"
host_config_rendered="$(mktemp)"
debug_workload_rendered="$(mktemp)"
vcluster_rendered="$(mktemp)"
trap 'rm -f "$controller_rendered" "$host_config_rendered" "$debug_workload_rendered" "$vcluster_rendered"' EXIT

assert_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq -- "$expected" "$file"; then
    printf 'missing expected content in %s: %s\n' "$file" "$expected" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local forbidden="$2"
  if grep -Fq -- "$forbidden" "$file"; then
    printf 'forbidden content in %s: %s\n' "$file" "$forbidden" >&2
    exit 1
  fi
}

assert_file_not_exists() {
  local file="$1"
  if [[ -e "$file" ]]; then
    printf 'forbidden file exists: %s\n' "$file" >&2
    exit 1
  fi
}

controller_overlay="$repo_root/components/litestream-controller/kustomization.yaml"
assert_contains "$controller_overlay" \
  'https://github.com/nakatanakatana/mytools//config/litestream-controller/default?ref=v0.7.0'

kustomize build "$repo_root/components/litestream-controller" >"$controller_rendered"
kustomize build "$repo_root/clusters/home/resources/litestream-debug" >"$host_config_rendered"
kustomize build "$repo_root/clusters/vcluster-app/feed-reader-debug/workload" >"$debug_workload_rendered"
kustomize build "$repo_root/clusters/vcluster-app" >"$vcluster_rendered"

assert_contains "$controller_rendered" \
  'ghcr.io/nakatanakatana/litestream-controller:0.7.0@sha256:5faa4c648f226e6bc497276d65fa6de42e3a661af91d1a14b64f5aa3baf30a08'
assert_not_contains "$controller_rendered" \
  'ghcr.io/nakatanakatana/litestream-controller:latest'
assert_contains "$controller_rendered" \
  'name: litestreams.litestream.mytools.nakatanakatana.app'
assert_contains "$controller_rendered" \
  'name: litestreamreplicas.litestream.mytools.nakatanakatana.app'

assert_contains "$host_config_rendered" 'namespace: app'
assert_contains "$host_config_rendered" 'name: feed-reader-db-debug-source'
assert_contains "$host_config_rendered" \
  'endpoint: http://storage-clusterip.tailscale.svc.cluster.local:8010'
assert_contains "$host_config_rendered" 'bucket: feed-reader'
assert_contains "$host_config_rendered" 'path: feed-reader.db'
assert_contains "$host_config_rendered" 'name: feed-reader-storage'
assert_contains "$host_config_rendered" 'key: access_key'
assert_contains "$host_config_rendered" 'key: access_secret'
assert_contains "$host_config_rendered" 'name: feed-reader-db-debug'
assert_contains "$host_config_rendered" 'ifReplicaMissing: fail'
assert_contains "$host_config_rendered" 'ifDatabaseExists: skip'
assert_not_contains "$host_config_rendered" 'replicate:'

assert_contains "$debug_workload_rendered" 'name: feed-reader-db-debug'
assert_contains "$debug_workload_rendered" \
  'litestream.mytools.nakatanakatana.app/inject: feed-reader-db-debug'
assert_contains "$debug_workload_rendered" \
  'litestream.mytools.nakatanakatana.app/target-container: sqlite3'
assert_contains "$debug_workload_rendered" \
  'litestream.mytools.nakatanakatana.app/volume: data'
assert_contains "$debug_workload_rendered" \
  'docker.io/keinos/sqlite3:3.50.4@sha256:7ea29f0c7e91a8c3f315e831459d07000f34e9e9b25fbc30be2e0481b3e0450f'
assert_contains "$debug_workload_rendered" 'name: sqlite3'
assert_contains "$debug_workload_rendered" 'sleep infinity'
assert_contains "$debug_workload_rendered" 'emptyDir: {}'
assert_not_contains "$debug_workload_rendered" 'kind: Service'
assert_not_contains "$debug_workload_rendered" 'kind: Ingress'

assert_contains "$repo_root/clusters/home/controllers/litestream-controller.yaml" \
  'name: cert-manager'
assert_contains "$repo_root/clusters/home/resources/litestream-debug.yaml" \
  'name: litestream-controller'
assert_contains "$repo_root/clusters/home/resources/vcluster-app-sync.yaml" \
  'name: litestream-debug'
assert_contains "$repo_root/clusters/home/_system/namespaces/app.yaml" \
  'litestream.mytools.nakatanakatana.app/injection: enabled'
assert_not_contains "$repo_root/clusters/vcluster-app/kustomization.yaml" \
  'litestream-controller.yaml'
assert_not_contains "$repo_root/clusters/vcluster-app/kustomization.yaml" \
  'feed-reader-debug-config.yaml'
assert_file_not_exists "$repo_root/clusters/vcluster-app/litestream-controller.yaml"
assert_file_not_exists "$repo_root/clusters/vcluster-app/feed-reader-debug-config.yaml"
assert_file_not_exists "$repo_root/clusters/vcluster-app/feed-reader-debug/config/litestream.yaml"
assert_file_not_exists "$repo_root/clusters/vcluster-app/feed-reader-debug/config/replica.yaml"
assert_not_contains "$vcluster_rendered" \
  'apiVersion: litestream.mytools.nakatanaka.app/v1alpha1'
assert_not_contains "$vcluster_rendered" \
  'litestreams.litestream.mytools.nakatanakatana.app'

printf '%s\n' 'Litestream controller and debug manifest contracts passed.'
