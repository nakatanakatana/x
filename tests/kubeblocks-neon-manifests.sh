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

assert_file_not_contains() {
  local file="$1"
  local forbidden="$2"
  if grep -Fq -- "$forbidden" "$file"; then
    printf 'forbidden content in %s: %s\n' "$file" "$forbidden" >&2
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

setup_doc="$repo_root/docs/kubeblocks-neon-setup.md"
for required_procedure in \
  'ComponentDefinition.spec.runtime` は immutable' \
  'patch kustomization/cluster-controllers' \
  'patch kustomization/cluster-resources' \
  'delete cluster/neon-demo' \
  'wait --for=delete cluster/neon-demo --timeout=10m' \
  'delete componentdefinition/neon-safekeeper-1.0.1' \
  $'flux reconcile helmrelease neon \\\n  --namespace=kb-system \\\n  --force \\\n  --with-source \\' \
  'get componentdefinition/neon-safekeeper-1.0.1' \
  'fsGroupChangePolicy' \
  'secret/neon-s3-credentials' \
  'rclone lsd pcloud:buckets' \
  'wait cluster/neon-demo' \
  '--timeout=20m'
do
  assert_file_contains "$setup_doc" "$required_procedure"
done

for required_cleanup in \
  'resume_cluster_reconciliation_on_exit()' \
  'local original_status=$?' \
  'trap resume_cluster_reconciliation_on_exit EXIT' \
  'return "$original_status"' \
  'cluster_reconciliation_resumed=true' \
  'trap - EXIT'
do
  assert_file_contains "$setup_doc" "$required_cleanup"
done

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
  'version: 1.0.2' \
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

neon_render_dir="$(mktemp -d)"
neon_rendered="$(mktemp)"
neon_external_secret="$(mktemp)"
neon_cluster="$(mktemp)"
trap 'rm -f "$rendered" "$neon_rendered" "$neon_external_secret" "$neon_cluster"; rm -rf "$neon_render_dir"' EXIT

cp "$repo_root/clusters/home/configs/external-secrets/neon.yaml" \
  "$neon_render_dir/neon.yaml"
cp "$repo_root/clusters/home/resources/neon-demo.yaml" \
  "$neon_render_dir/neon-demo.yaml"
printf '%s\n' \
  'apiVersion: kustomize.config.k8s.io/v1beta1' \
  'kind: Kustomization' \
  'resources:' \
  '  - neon.yaml' \
  '  - neon-demo.yaml' \
  >"$neon_render_dir/kustomization.yaml"
kustomize build "$neon_render_dir" >"$neon_rendered"

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
    printf 'expected exactly one %s/%s resource in %s\n' "$kind" "$name" "$source" >&2
    exit 1
  fi
}

extract_component() {
  local cluster="$1"
  local component_name="$2"
  local destination="$3"

  if ! awk -v expected_name="$component_name" '
    /^  componentSpecs:/ {
      in_component_specs = 1
      next
    }
    in_component_specs && /^  - name: / {
      if (found) {
        exit
      }
      current_name = substr($0, 11)
      if (current_name == expected_name) {
        found = 1
      }
    }
    found {
      print
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$cluster" >"$destination"; then
    printf 'expected component %s in Cluster resource\n' "$component_name" >&2
    exit 1
  fi
}

assert_resource_contains() {
  local resource="$1"
  local expected="$2"
  if ! grep -Fq -- "$expected" "$resource"; then
    printf 'missing expected content in %s: %s\n' "$resource" "$expected" >&2
    exit 1
  fi
}

assert_volume_claim_templates() {
  local component_resource="$1"
  local expected_capacity="$2"

  if ! awk -v expected_capacity="$expected_capacity" '
    /^    volumeClaimTemplates:/ {
      in_templates = 1
      next
    }
    in_templates && /^    - name: / {
      if (templates > 0 && (!has_storage_class || !has_capacity)) {
        exit 1
      }
      templates++
      has_storage_class = 0
      has_capacity = 0
      next
    }
    in_templates && /^        storageClassName: rook-ceph-block$/ {
      has_storage_class = 1
    }
    in_templates && "            storage: " expected_capacity == $0 {
      has_capacity = 1
    }
    END {
      if (templates == 0 || !has_storage_class || !has_capacity) {
        exit 1
      }
    }
  ' "$component_resource"; then
    printf 'every volume claim template must use rook-ceph-block with %s\n' "$expected_capacity" >&2
    exit 1
  fi
}

extract_resource "$neon_rendered" ExternalSecret neon-s3-credentials "$neon_external_secret"
extract_resource "$neon_rendered" Cluster neon-demo "$neon_cluster"

assert_resource_contains "$neon_external_secret" "apiVersion: external-secrets.io/v1"
assert_resource_contains "$neon_external_secret" "namespace: database"
assert_resource_contains "$neon_external_secret" "kind: ClusterSecretStore"
assert_resource_contains "$neon_external_secret" "name: 1password-sdk"
assert_resource_contains "$neon_external_secret" "refreshInterval: 18h43m"
assert_resource_contains "$neon_external_secret" "creationPolicy: Owner"
assert_resource_contains "$neon_external_secret" $'target:\n    creationPolicy: Owner\n    name: neon-s3-credentials'
assert_resource_contains "$neon_external_secret" "secretKey: AWS_ACCESS_KEY_ID"
assert_resource_contains "$neon_external_secret" "key: pcloud-s3/S3_ACCESS_KEY_ID"
assert_resource_contains "$neon_external_secret" "secretKey: AWS_SECRET_ACCESS_KEY"
assert_resource_contains "$neon_external_secret" "key: pcloud-s3/S3_SECRET_ACCESS_KEY"

assert_resource_contains "$neon_cluster" "apiVersion: apps.kubeblocks.io/v1"
assert_resource_contains "$neon_cluster" "namespace: database"
assert_resource_contains "$neon_cluster" "clusterDef: neon"
assert_file_not_contains "$neon_cluster" "clusterDefinitionRef:"
assert_resource_contains "$neon_cluster" "topology: default"
assert_resource_contains "$neon_cluster" "terminationPolicy: Delete"

component_rendered="$(mktemp)"
neon_helm_release="$(mktemp)"
neon_chart_render_dir="$(mktemp -d)"
neon_chart_rendered="$neon_chart_render_dir/neon-rendered.yaml"
neon_chart_post_rendered="$neon_chart_render_dir/neon-post-rendered.yaml"
neon_safekeeper_rendered="$neon_chart_render_dir/neon-safekeeper-rendered.yaml"
neon_safekeeper_post_rendered="$neon_chart_render_dir/neon-safekeeper-post-rendered.yaml"
trap 'rm -f "$rendered" "$neon_rendered" "$neon_external_secret" "$neon_cluster" "$component_rendered" "$neon_helm_release"; rm -rf "$neon_render_dir" "$neon_chart_render_dir"' EXIT
extract_resource "$rendered" HelmRelease neon "$neon_helm_release"

cp "$repo_root/tests/fixtures/neon-component-versions-1.0.1.yaml" \
  "$neon_chart_rendered"
python3 "$repo_root/tests/kubeblocks_neon_postrender.py" write-kustomization \
  "$neon_helm_release" \
  "$neon_chart_rendered" \
  "$neon_chart_render_dir/kustomization.yaml"
kustomize build "$neon_chart_render_dir" >"$neon_chart_post_rendered"
python3 "$repo_root/tests/kubeblocks_neon_postrender.py" validate \
  "$neon_chart_post_rendered" \
  "$repo_root/components/kubeblocks-crds/kubeblocks_crds.yaml"

cp "$repo_root/tests/fixtures/neon-safekeeper-component-definition-1.0.1.yaml" \
  "$neon_safekeeper_rendered"
python3 "$repo_root/tests/kubeblocks_neon_postrender.py" write-kustomization \
  "$neon_helm_release" \
  "$neon_safekeeper_rendered" \
  "$neon_chart_render_dir/kustomization.yaml"
kustomize build "$neon_chart_render_dir" >"$neon_safekeeper_post_rendered"
python3 "$repo_root/tests/kubeblocks_neon_postrender.py" validate-safekeeper \
  "$neon_safekeeper_post_rendered" \
  "$repo_root/components/kubeblocks-crds/kubeblocks_crds.yaml"

for component_spec in \
  'neon-pageserver:1:data:10Gi' \
  'neon-safekeeper:3:data:5Gi' \
  'neon-compute:1:data:5Gi'
do
  IFS=: read -r component replicas volume capacity <<<"$component_spec"
  extract_component "$neon_cluster" "$component" "$component_rendered"
  assert_resource_contains "$component_rendered" "replicas: $replicas"
  assert_resource_contains "$component_rendered" "name: $volume"
  assert_volume_claim_templates "$component_rendered" "$capacity"
  assert_resource_contains "$component_rendered" "cpu: 500m"
  assert_resource_contains "$component_rendered" "memory: 512Mi"
  assert_resource_contains "$component_rendered" 'cpu: "1"'
  assert_resource_contains "$component_rendered" "memory: 2Gi"
done

extract_component "$neon_cluster" "neon-broker" "$component_rendered"
assert_resource_contains "$component_rendered" "replicas: 1"
assert_resource_contains "$component_rendered" "cpu: 500m"
assert_resource_contains "$component_rendered" "memory: 512Mi"
assert_resource_contains "$component_rendered" 'cpu: "1"'
assert_resource_contains "$component_rendered" "memory: 2Gi"
assert_file_not_contains "$component_rendered" "volumeClaimTemplates:"
assert_resource_contains "$component_rendered" "schedulingPolicy:"
assert_resource_contains "$component_rendered" "kubernetes.io/arch: amd64"

for forbidden in NodePort LoadBalancer WipeOut; do
  if grep -Fq -- "$forbidden" "$neon_cluster"; then
    printf 'forbidden Cluster configuration remains: %s\n' "$forbidden" >&2
    exit 1
  fi
done

if rg --pcre2 --glob '*.yaml' --glob '*.yml' -n \
  '^[[:space:]]*(-[[:space:]]+)?(AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|S3_ACCESS_KEY_ID|S3_SECRET_ACCESS_KEY):[[:space:]]*(?!["'"'"']?\{\{)[^#[:space:]][^#]*$' \
  "$repo_root"; then
  printf '%s\n' 'literal S3 credential value remains in YAML' >&2
  exit 1
fi

python3 "$repo_root/tests/kubeblocks_neon_contracts.py"
