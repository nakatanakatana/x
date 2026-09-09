#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: velero-restore-pvc.sh <backup-name> <source-namespace> <source-pvc> <target-pvc>
       velero-restore-pvc.sh --restore-id <restore-id> <backup-name> <source-namespace> <source-pvc> <target-pvc>

Restores a single PersistentVolumeClaim from a Velero backup into a new PVC
within the source namespace using a Velero resource modifier ConfigMap.

Arguments:
  --restore-id      Use this label value instead of reading it from the source PVC.
                    Use during disaster recovery when the source PVC is absent.
  backup-name       Name of the Velero Backup (must be Completed or PartiallyFailed)
  source-namespace  Namespace of the original PVC
  source-pvc        Name of the original PVC in the backup
  target-pvc        Name of the new target PVC to create (must not already exist)

Each argument must be a valid Kubernetes DNS label:
  - At most 63 characters
  - Lowercase alphanumeric characters or '-'
  - Start and end with an alphanumeric character
EOF
  exit 1
}

# 1. Optional restore selector and argument count check
# Must exit non-zero immediately without contacting the cluster when argument count is wrong.
RESTORE_ID_OVERRIDE=""
if [[ $# -eq 6 && "$1" == "--restore-id" ]]; then
  RESTORE_ID_OVERRIDE="$2"
  shift 2
fi

if [[ $# -ne 4 ]]; then
  usage
fi

BACKUP_NAME="$1"
SOURCE_NAMESPACE="$2"
SOURCE_PVC="$3"
TARGET_PVC="$4"

# 2. Argument validation (Kubernetes DNS-1123 label)
# Validates: 1-63 chars, lowercase alphanumeric or '-', starts/ends with alphanumeric.
is_dns_label() {
  local val="$1"
  if [[ ${#val} -lt 1 || ${#val} -gt 63 ]]; then
    return 1
  fi
  if [[ "$val" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]; then
    return 0
  fi
  return 1
}

for arg_var in BACKUP_NAME SOURCE_NAMESPACE SOURCE_PVC TARGET_PVC; do
  arg_val="${!arg_var}"
  if ! is_dns_label "${arg_val}"; then
    echo "Error: Argument '${arg_var}' ('${arg_val}') is not a valid Kubernetes DNS label." >&2
    echo "It must consist of lowercase alphanumeric characters or '-', start and end with an alphanumeric character, and be 1 to 63 characters long." >&2
    exit 1
  fi
done

if [[ -n "${RESTORE_ID_OVERRIDE}" ]] && ! is_dns_label "${RESTORE_ID_OVERRIDE}"; then
  echo "Error: Argument 'restore-id' ('${RESTORE_ID_OVERRIDE}') is not a valid Kubernetes DNS label." >&2
  echo "It must consist of lowercase alphanumeric characters or '-', start and end with an alphanumeric character, and be 1 to 63 characters long." >&2
  exit 1
fi

VELERO_NAMESPACE="velero"
REQUEST_TIMEOUT="30s"

# 3. Check if target PVC already exists in source namespace
# Never overwrite, delete, or patch an existing PVC. --ignore-not-found makes
# only a confirmed NotFound result continue; API/authentication errors stop the
# script instead of being treated as an absent PVC.
if ! TARGET_PVC_RESOURCE=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${SOURCE_NAMESPACE}" get pvc "${TARGET_PVC}" --ignore-not-found -o name); then
  echo "Error: Could not verify whether target PVC '${TARGET_PVC}' exists in namespace '${SOURCE_NAMESPACE}'." >&2
  echo "Refusing to proceed while the cluster state cannot be verified." >&2
  exit 1
fi

if [[ -n "${TARGET_PVC_RESOURCE}" ]]; then
  echo "Error: Target PVC '${TARGET_PVC}' already exists in namespace '${SOURCE_NAMESPACE}'." >&2
  echo "Refusing to proceed to avoid modifying or overwriting an existing PVC." >&2
  exit 1
fi

# 4. Verify a unique restore selector label.
# The Restore labelSelector prevents Velero from restoring every PVC in the
# source namespace when the namespace is empty during disaster recovery.
if [[ -n "${RESTORE_ID_OVERRIDE}" ]]; then
  SOURCE_RESTORE_ID="${RESTORE_ID_OVERRIDE}"
else
  if ! SOURCE_RESTORE_ID=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${SOURCE_NAMESPACE}" get pvc "${SOURCE_PVC}" -o 'go-template={{ with index .metadata.labels "backup.pcloud.io/restore-id" }}{{ . }}{{ end }}'); then
    echo "Error: Could not read source PVC '${SOURCE_NAMESPACE}/${SOURCE_PVC}'." >&2
    echo "Refusing to proceed without a source PVC restore selector." >&2
    echo "If the source PVC was deleted during disaster recovery, rerun with --restore-id." >&2
    exit 1
  fi

  if [[ -z "${SOURCE_RESTORE_ID}" ]]; then
    echo "Error: Source PVC '${SOURCE_NAMESPACE}/${SOURCE_PVC}' is missing the 'backup.pcloud.io/restore-id' label." >&2
    echo "Restore requires a backup created after the per-PVC restore label was deployed." >&2
    exit 1
  fi
fi

# 5. Verify Velero Backup exists and check .status.phase
# Read only .status.phase; stop for empty or any phase other than Completed or PartiallyFailed.
# Never prints Secret data.
BACKUP_PHASE=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${VELERO_NAMESPACE}" get backup "${BACKUP_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)

if [[ -z "${BACKUP_PHASE}" ]]; then
  echo "Error: Velero Backup '${BACKUP_NAME}' not found in namespace '${VELERO_NAMESPACE}' or has no phase." >&2
  exit 1
fi

if [[ "${BACKUP_PHASE}" != "Completed" && "${BACKUP_PHASE}" != "PartiallyFailed" ]]; then
  echo "Error: Velero Backup '${BACKUP_NAME}' phase is '${BACKUP_PHASE}'." >&2
  echo "Restore requires backup phase to be 'Completed' or 'PartiallyFailed'." >&2
  exit 1
fi

# 6. Generate unique DNS-safe names for ConfigMap and Restore
# Form: prefix-YYYYMMDDHHMMSS-randomhex (all lowercase alphanumeric/hyphen, well within 63 chars)
RANDOM_SUFFIX=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
TIMESTAMP=$(date -u +%Y%m%d%H%M%S)

CONFIGMAP_NAME="restore-mod-${TIMESTAMP}-${RANDOM_SUFFIX}"
RESTORE_NAME="restore-${TIMESTAMP}-${RANDOM_SUFFIX}"

if ! is_dns_label "${CONFIGMAP_NAME}" || ! is_dns_label "${RESTORE_NAME}"; then
  echo "Error: Generated name '${CONFIGMAP_NAME}' or '${RESTORE_NAME}' is invalid." >&2
  exit 1
fi

# 7. Create temporary directory and ensure cleanup on exit
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

# 8. Create resource-modifier ConfigMap in namespace velero
cat <<EOF > "${TMP_DIR}/resource-modifier-cm.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: "${CONFIGMAP_NAME}"
  namespace: "${VELERO_NAMESPACE}"
data:
  resource-modifier.yaml: |
    version: v1
    resourceModifierRules:
    - conditions:
        groupResource: persistentvolumeclaims
        resourceNameRegex: "^${SOURCE_PVC}$"
        namespaces:
        - "${SOURCE_NAMESPACE}"
      patches:
      - operation: replace
        path: /metadata/name
        value: "${TARGET_PVC}"
EOF

kubectl --request-timeout="${REQUEST_TIMEOUT}" apply -f "${TMP_DIR}/resource-modifier-cm.yaml"

# 9. Create Restore resource in namespace velero
cat <<EOF > "${TMP_DIR}/restore.yaml"
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: "${RESTORE_NAME}"
  namespace: "${VELERO_NAMESPACE}"
spec:
  backupName: "${BACKUP_NAME}"
  includedNamespaces:
  - "${SOURCE_NAMESPACE}"
  includedResources:
  - persistentvolumeclaims
  labelSelector:
    matchLabels:
      backup.pcloud.io/restore-id: "${SOURCE_RESTORE_ID}"
  restorePVs: true
  existingResourcePolicy: none
  resourceModifier:
    kind: ConfigMap
    name: "${CONFIGMAP_NAME}"
EOF

if ! kubectl --request-timeout="${REQUEST_TIMEOUT}" apply -f "${TMP_DIR}/restore.yaml"; then
  echo "Error: Failed to create Restore resource '${RESTORE_NAME}' in namespace '${VELERO_NAMESPACE}'." >&2
  if kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${VELERO_NAMESPACE}" delete configmap "${CONFIGMAP_NAME}" --ignore-not-found >/dev/null 2>&1; then
    echo "The resource modifier ConfigMap '${CONFIGMAP_NAME}' was cleaned up." >&2
  else
    echo "The resource modifier ConfigMap '${CONFIGMAP_NAME}' could not be cleaned up automatically:" >&2
    echo "   kubectl -n ${VELERO_NAMESPACE} delete configmap ${CONFIGMAP_NAME}" >&2
  fi
  exit 1
fi

# 10. Output results and operational instructions
cat <<EOF

================================================================================
Restore requested successfully.
================================================================================
Restore Name:                ${RESTORE_NAME}
Resource Modifier ConfigMap: ${CONFIGMAP_NAME}
Backup Name:                 ${BACKUP_NAME}
Source PVC:                  ${SOURCE_NAMESPACE}/${SOURCE_PVC}
Target PVC:                  ${SOURCE_NAMESPACE}/${TARGET_PVC}

--- Inspection Commands (Read-only) ---
1. Monitor Restore status:
   kubectl -n ${VELERO_NAMESPACE} get restore ${RESTORE_NAME} -o wide
   kubectl -n ${VELERO_NAMESPACE} describe restore ${RESTORE_NAME}

2. Monitor Velero DataDownload progress:
   kubectl -n ${VELERO_NAMESPACE} get datadownloads.velero.io -l velero.io/restore-name=${RESTORE_NAME}
   kubectl -n ${VELERO_NAMESPACE} get datadownloads.velero.io

3. Monitor the restored target PVC until it becomes Bound:
   kubectl -n ${SOURCE_NAMESPACE} get pvc ${TARGET_PVC} -w

--- ConfigMap Cleanup Instruction ---
Important: The resource modifier ConfigMap '${CONFIGMAP_NAME}' must remain in place
until the Restore reaches a terminal state (Completed, Failed, or PartiallyFailed).
Do NOT delete it while the restore is in progress.

Once the restore has reached a terminal state, delete the ConfigMap manually:
   kubectl -n ${VELERO_NAMESPACE} delete configmap ${CONFIGMAP_NAME}

EOF
