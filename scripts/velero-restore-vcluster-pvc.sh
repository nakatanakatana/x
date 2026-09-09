#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: velero-restore-vcluster-pvc.sh --confirm-workload-stopped \
  <backup-name> <host-namespace> <source-host-pvc> <target-host-pvc>

Restores a vCluster-synchronized host PVC through a staging PVC and copies the
restored data into an existing vCluster-managed host PVC. The target PVC stays
bound to the existing virtual PVC; no vCluster workload manifest is changed.

The target PVC contents are replaced. Stop every workload using the target PVC
before running this command and pass --confirm-workload-stopped explicitly.

Environment variables:
  RESTORE_TIMEOUT_SECONDS  Maximum time to wait for Velero and the copy Job
                           (default: 21600, six hours)
  POLL_INTERVAL_SECONDS    Poll interval (default: 10)
EOF
  exit 1
}

if [[ $# -ne 5 || "$1" != "--confirm-workload-stopped" ]]; then
  usage
fi

shift
BACKUP_NAME="$1"
HOST_NAMESPACE="$2"
SOURCE_HOST_PVC="$3"
TARGET_HOST_PVC="$4"

is_dns_label() {
  local val="$1"
  if [[ ${#val} -lt 1 || ${#val} -gt 63 ]]; then
    return 1
  fi
  [[ "$val" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]
}

for arg_var in BACKUP_NAME HOST_NAMESPACE SOURCE_HOST_PVC TARGET_HOST_PVC; do
  arg_val="${!arg_var}"
  if ! is_dns_label "${arg_val}"; then
    echo "Error: Argument '${arg_var}' ('${arg_val}') is not a valid Kubernetes DNS label." >&2
    exit 1
  fi
done

VELERO_NAMESPACE="velero"
REQUEST_TIMEOUT="30s"
RESTORE_TIMEOUT_SECONDS="${RESTORE_TIMEOUT_SECONDS:-21600}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"

if ! [[ "${RESTORE_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] ||
  ! [[ "${POLL_INTERVAL_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: RESTORE_TIMEOUT_SECONDS and POLL_INTERVAL_SECONDS must be positive integers." >&2
  exit 1
fi

if ! TARGET_PHASE=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${HOST_NAMESPACE}" get pvc "${TARGET_HOST_PVC}" -o jsonpath='{.status.phase}'); then
  echo "Error: Could not read target PVC '${HOST_NAMESPACE}/${TARGET_HOST_PVC}'." >&2
  exit 1
fi

if [[ "${TARGET_PHASE}" != "Bound" ]]; then
  echo "Error: Target PVC '${HOST_NAMESPACE}/${TARGET_HOST_PVC}' is not Bound (phase: '${TARGET_PHASE}')." >&2
  exit 1
fi

if ! TARGET_MANAGED_BY=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${HOST_NAMESPACE}" get pvc "${TARGET_HOST_PVC}" -o 'go-template={{ with index .metadata.labels "vcluster.loft.sh/managed-by" }}{{ . }}{{ end }}'); then
  echo "Error: Could not verify vCluster ownership of target PVC '${HOST_NAMESPACE}/${TARGET_HOST_PVC}'." >&2
  exit 1
fi

TARGET_VCLUSTER_NAME=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${HOST_NAMESPACE}" get pvc "${TARGET_HOST_PVC}" -o 'go-template={{ with index .metadata.labels "vcluster.loft.sh/name" }}{{ . }}{{ end }}')
TARGET_VCLUSTER_NAMESPACE=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${HOST_NAMESPACE}" get pvc "${TARGET_HOST_PVC}" -o 'go-template={{ with index .metadata.labels "vcluster.loft.sh/namespace" }}{{ . }}{{ end }}')

if [[ "${TARGET_MANAGED_BY}" != "vcluster" || -z "${TARGET_VCLUSTER_NAME}" || -z "${TARGET_VCLUSTER_NAMESPACE}" ]]; then
  echo "Error: Target PVC '${HOST_NAMESPACE}/${TARGET_HOST_PVC}' is not a recognizable vCluster-managed PVC." >&2
  echo "Expected vcluster.loft.sh/managed-by, vcluster.loft.sh/name, and vcluster.loft.sh/namespace labels." >&2
  exit 1
fi

if [[ "${TARGET_VCLUSTER_NAMESPACE}" != "${HOST_NAMESPACE}" ]]; then
  echo "Error: Target PVC reports vCluster host namespace '${TARGET_VCLUSTER_NAMESPACE}', expected '${HOST_NAMESPACE}'." >&2
  exit 1
fi

if ! SOURCE_RESTORE_ID=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${HOST_NAMESPACE}" get pvc "${SOURCE_HOST_PVC}" -o 'go-template={{ with index .metadata.labels "backup.pcloud.io/restore-id" }}{{ . }}{{ end }}'); then
  echo "Error: Could not read source PVC '${HOST_NAMESPACE}/${SOURCE_HOST_PVC}'." >&2
  exit 1
fi

if [[ -z "${SOURCE_RESTORE_ID}" ]]; then
  echo "Error: Source PVC '${HOST_NAMESPACE}/${SOURCE_HOST_PVC}' is missing the 'backup.pcloud.io/restore-id' label." >&2
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

RANDOM_SUFFIX=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
TIMESTAMP=$(date -u +%Y%m%d%H%M%S)
STAGING_PVC="vcluster-restore-stage-${TIMESTAMP}-${RANDOM_SUFFIX}"
COPY_JOB_NAME="vcluster-restore-copy-${TIMESTAMP}-${RANDOM_SUFFIX}"

if ! is_dns_label "${STAGING_PVC}" || ! is_dns_label "${COPY_JOB_NAME}"; then
  echo "Error: Generated staging PVC or copy Job name is invalid." >&2
  exit 1
fi

echo "Creating a Velero restore into staging PVC '${HOST_NAMESPACE}/${STAGING_PVC}'." >&2
if ! "${SCRIPT_DIR}/velero-restore-pvc.sh" \
  "${BACKUP_NAME}" "${HOST_NAMESPACE}" "${SOURCE_HOST_PVC}" "${STAGING_PVC}" \
  >"${TMP_DIR}/restore-output"; then
  cat "${TMP_DIR}/restore-output"
  exit 1
fi
cat "${TMP_DIR}/restore-output"

RESTORE_NAME=$(sed -n 's/^Restore Name:[[:space:]]*//p' "${TMP_DIR}/restore-output" | head -n 1)
if [[ -z "${RESTORE_NAME}" ]]; then
  echo "Error: Could not determine the Velero Restore name from the restore script output." >&2
  exit 1
fi

deadline=$((SECONDS + RESTORE_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  RESTORE_PHASE=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${VELERO_NAMESPACE}" get restore "${RESTORE_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  case "${RESTORE_PHASE}" in
    Completed)
      break
      ;;
    PartiallyFailed|Failed|FailedValidation)
      echo "Error: Velero Restore '${RESTORE_NAME}' ended in phase '${RESTORE_PHASE}'." >&2
      exit 1
      ;;
  esac
  sleep "${POLL_INTERVAL_SECONDS}"
done

if [[ "${RESTORE_PHASE:-}" != "Completed" ]]; then
  echo "Error: Timed out waiting for Velero Restore '${RESTORE_NAME}' to complete." >&2
  exit 1
fi

deadline=$((SECONDS + RESTORE_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  DOWNLOAD_PHASES=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${VELERO_NAMESPACE}" \
    get datadownloads.velero.io -l "velero.io/restore-name=${RESTORE_NAME}" \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true)

  if [[ -n "${DOWNLOAD_PHASES}" ]]; then
    DOWNLOAD_FAILED=false
    DOWNLOADS_COMPLETE=true
    while IFS= read -r phase; do
      [[ -z "${phase}" ]] && continue
      case "${phase}" in
        Completed) ;;
        Failed|Canceled)
          DOWNLOAD_FAILED=true
          ;;
        *)
          DOWNLOADS_COMPLETE=false
          ;;
      esac
    done <<<"${DOWNLOAD_PHASES}"

    if [[ "${DOWNLOAD_FAILED}" == true ]]; then
      echo "Error: A DataDownload for Restore '${RESTORE_NAME}' failed." >&2
      exit 1
    fi
    if [[ "${DOWNLOADS_COMPLETE}" == true ]]; then
      break
    fi
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
done

if [[ "${DOWNLOADS_COMPLETE:-false}" != true ]]; then
  echo "Error: Timed out waiting for DataDownload resources for Restore '${RESTORE_NAME}'." >&2
  exit 1
fi

deadline=$((SECONDS + RESTORE_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  STAGING_PHASE=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${HOST_NAMESPACE}" get pvc "${STAGING_PVC}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "${STAGING_PHASE}" == "Bound" ]]; then
    break
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
done

if [[ "${STAGING_PHASE:-}" != "Bound" ]]; then
  echo "Error: Timed out waiting for staging PVC '${HOST_NAMESPACE}/${STAGING_PVC}' to become Bound." >&2
  exit 1
fi

echo "Copying restored data into vCluster-managed PVC '${HOST_NAMESPACE}/${TARGET_HOST_PVC}'." >&2
kubectl --request-timeout="${REQUEST_TIMEOUT}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: "${COPY_JOB_NAME}"
  namespace: "${HOST_NAMESPACE}"
  labels:
    backup.pcloud.io/restore-job: "${COPY_JOB_NAME}"
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        backup.pcloud.io/restore-job: "${COPY_JOB_NAME}"
    spec:
      restartPolicy: Never
      containers:
        - name: copy
          image: busybox:1.36.1
          command:
            - /bin/sh
            - -ec
          args:
            - |
              find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
              tar -C /source -cf - . | tar -C /target -xf -
          volumeMounts:
            - name: source
              mountPath: /source
              readOnly: true
            - name: target
              mountPath: /target
      volumes:
        - name: source
          persistentVolumeClaim:
            claimName: "${STAGING_PVC}"
        - name: target
          persistentVolumeClaim:
            claimName: "${TARGET_HOST_PVC}"
EOF

deadline=$((SECONDS + RESTORE_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  JOB_SUCCEEDED=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${HOST_NAMESPACE}" get job "${COPY_JOB_NAME}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
  JOB_FAILED=$(kubectl --request-timeout="${REQUEST_TIMEOUT}" -n "${HOST_NAMESPACE}" get job "${COPY_JOB_NAME}" -o jsonpath='{.status.failed}' 2>/dev/null || true)
  if [[ "${JOB_SUCCEEDED}" == "1" ]]; then
    break
  fi
  if [[ "${JOB_FAILED}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: Copy Job '${HOST_NAMESPACE}/${COPY_JOB_NAME}' failed." >&2
    exit 1
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
done

if [[ "${JOB_SUCCEEDED:-}" != "1" ]]; then
  echo "Error: Timed out waiting for Copy Job '${HOST_NAMESPACE}/${COPY_JOB_NAME}'." >&2
  exit 1
fi

cat <<EOF

================================================================================
vCluster PVC restore completed.
================================================================================
vCluster:                   ${TARGET_VCLUSTER_NAMESPACE}/${TARGET_VCLUSTER_NAME}
Velero Restore:             ${RESTORE_NAME}
Staging PVC:                ${HOST_NAMESPACE}/${STAGING_PVC}
Copy Job:                   ${HOST_NAMESPACE}/${COPY_JOB_NAME}
Target PVC:                 ${HOST_NAMESPACE}/${TARGET_HOST_PVC}

The existing vCluster-managed target PVC was kept in place and its contents
were replaced from the restored staging PVC. Verify application data before
restarting workloads, then remove the staging PVC:
  kubectl -n ${HOST_NAMESPACE} delete pvc ${STAGING_PVC}

EOF
