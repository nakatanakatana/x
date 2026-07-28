#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rendered="$(mktemp)"
service="$(mktemp)"
pvc="$(mktemp)"
deployment="$(mktemp)"
namespace="$(mktemp)"
trap 'rm -f "$rendered" "$service" "$pvc" "$deployment" "$namespace"' EXIT

kustomize build "$repo_root/components/pcloud-s3" >"$rendered"

extract_resource() {
  local source="$1"
  local kind="$2"
  local name="$3"
  local destination="$4"

  if ! awk -v expected_kind="$kind" -v expected_name="$name" '
    function reset_resource() {
      document = ""
      kind = ""
      name = ""
      in_metadata = 0
    }
    function emit_resource() {
      if (kind == expected_kind && name == expected_name) {
        printf "%s", document
        matches++
      }
    }
    BEGIN {
      reset_resource()
    }
    /^---[[:space:]]*$/ {
      emit_resource()
      reset_resource()
      next
    }
    {
      document = document $0 ORS
      if ($0 ~ /^kind: /) {
        kind = substr($0, 7)
      } else if ($0 == "metadata:") {
        in_metadata = 1
      } else if (in_metadata && $0 ~ /^  name: /) {
        name = substr($0, 9)
      } else if (in_metadata && $0 ~ /^[^[:space:]]/) {
        in_metadata = 0
      }
    }
    END {
      emit_resource()
      if (matches != 1) {
        exit 1
      }
    }
  ' "$source" >"$destination"; then
    echo "expected exactly one $kind/$name resource in $source" >&2
    exit 1
  fi
}

assert_contains() {
  local resource="$1"
  local expected="$2"
  if ! grep -Fq -- "$expected" "$resource"; then
    echo "missing expected content in $resource: $expected" >&2
    exit 1
  fi
}

assert_no_kind() {
  local kind="$1"
  if awk -v expected="kind: $kind" '$0 == expected { found = 1 } END { exit !found }' "$rendered"; then
    echo "unexpected rendered resource kind: $kind" >&2
    exit 1
  fi
}

assert_no_service_type() {
  local type="$1"
  if awk -v unexpected="  type: $type" '
    /^---[[:space:]]*$/ {
      in_service = 0
    }
    $0 == "kind: Service" {
      in_service = 1
    }
    in_service && $0 == unexpected {
      found = 1
    }
    END {
      exit !found
    }
  ' "$rendered"; then
    echo "unexpected rendered Service type: $type" >&2
    exit 1
  fi
}

extract_resource "$rendered" Service gateway "$service"
extract_resource "$rendered" PersistentVolumeClaim rclone-s3-cache "$pvc"
extract_resource "$rendered" Deployment rclone-s3-gateway "$deployment"
extract_resource \
  "$repo_root/clusters/home/_system/namespaces/pcloud-s3.yaml" \
  Namespace \
  pcloud-s3 \
  "$namespace"

assert_contains "$service" "type: ClusterIP"
assert_contains "$service" "port: 8080"
assert_contains "$service" $'selector:\n    app: rclone-s3-gateway'
assert_no_service_type NodePort
assert_no_service_type LoadBalancer
assert_no_kind Ingress

assert_contains "$pvc" "kustomize.toolkit.fluxcd.io/prune: disabled"
assert_contains "$pvc" "storageClassName: rook-ceph-block"
assert_contains "$pvc" "- ReadWriteOnce"
assert_contains "$pvc" "storage: 50Gi"

assert_contains "$namespace" "kustomize.toolkit.fluxcd.io/prune: disabled"

assert_contains "$deployment" "replicas: 1"
assert_contains "$deployment" "type: Recreate"
assert_contains "$deployment" $'selector:\n    matchLabels:\n      app: rclone-s3-gateway'
assert_contains "$deployment" $'template:\n    metadata:\n      labels:\n        app: rclone-s3-gateway'
assert_contains "$deployment" "rclone/rclone:1.74.4@sha256:c61954aaa32328a5486715dd063a81c7879f5195ad3505cd362deddd509dc4a1"
assert_contains "$deployment" "value: pcloud"
assert_contains "$deployment" "value: api.pcloud.com"
assert_contains "$deployment" $'secretKeyRef:\n              key: PCLOUD_TOKEN\n              name: rclone-s3-credentials'
assert_contains "$deployment" $'secretKeyRef:\n              key: RCLONE_AUTH_KEY\n              name: rclone-s3-credentials'
assert_contains "$deployment" "- pcloud:buckets"
assert_contains "$deployment" "- --addr=:8080"
assert_contains "$deployment" "- --log-level=NOTICE"
assert_contains "$deployment" "- --vfs-cache-mode=writes"
assert_contains "$deployment" "- --cache-dir=/cache"
assert_contains "$deployment" "- --dir-cache-time=1h"
assert_contains "$deployment" "- --poll-interval=5m"
assert_contains "$deployment" "- --vfs-cache-max-size=45Gi"
assert_contains "$deployment" "- --vfs-cache-min-free-space=2Gi"
assert_contains "$deployment" "- --vfs-cache-max-age=24h"
assert_contains "$deployment" "- --vfs-cache-poll-interval=1m"
assert_contains "$deployment" "- --vfs-write-back=5s"
assert_contains "$deployment" "- --transfers=2"
assert_contains "$deployment" "- --buffer-size=16Mi"
assert_contains "$deployment" $'volumeMounts:\n        - mountPath: /cache\n          name: cache'
assert_contains "$deployment" $'- name: cache\n        persistentVolumeClaim:\n          claimName: rclone-s3-cache'
assert_contains "$deployment" "automountServiceAccountToken: false"
assert_contains "$deployment" $'securityContext:\n          allowPrivilegeEscalation: false\n          capabilities:\n            drop:\n            - ALL\n          readOnlyRootFilesystem: true'
assert_contains "$deployment" $'securityContext:\n        fsGroup: 1009\n        fsGroupChangePolicy: OnRootMismatch\n        runAsGroup: 1009\n        runAsNonRoot: true\n        runAsUser: 1009\n        seccompProfile:\n          type: RuntimeDefault'
