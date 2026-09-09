#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *" get pvc "* && " $* " == *" -o name "* ]]; then
  exit 0
fi

if [[ " $* " == *" get pvc "* && " $* " == *"go-template="* ]]; then
  if [[ "${FAKE_SOURCE_PVC_MISSING:-}" == "1" ]]; then
    exit 1
  fi
  printf '%s' "${FAKE_RESTORE_ID:-feed-reader-feed-reader-data}"
  exit 0
fi

if [[ " $* " == *" get backup "* ]]; then
  printf '%s' "Completed"
  exit 0
fi

if [[ " $* " == *" apply -f "* ]]; then
  manifest_path=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "-f" ]]; then
      manifest_path="$arg"
      break
    fi
    previous="$arg"
  done

  if [[ -z "$manifest_path" ]]; then
    exit 2
  fi

  if [[ "${FAKE_FAIL_RESTORE_APPLY:-}" == "1" ]] && grep -q '^kind: Restore$' "$manifest_path"; then
    exit 1
  fi

  cat "$manifest_path" >> "${FAKE_KUBECTL_APPLY_LOG:?}"
  exit 0
fi

if [[ " $* " == *" delete configmap "* ]]; then
  printf '%s\n' "delete configmap" >> "${FAKE_KUBECTL_DELETE_LOG:?}"
  exit 0
fi

printf 'unexpected fake kubectl invocation: %s\n' "$*" >&2
exit 2
