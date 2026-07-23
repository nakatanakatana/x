#!/usr/bin/env bash
set -euo pipefail

BASE_REF="${1:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== 1. Rendering current workspace manifests ==="
mkdir -p /tmp/manifests
python3 "${SCRIPT_DIR}/.github/scripts/render-manifests.py" /tmp/manifests/pr-rendered.yaml

echo "=== 2. Running Kubeconform Schema Validation ==="
if command -v kubeconform >/dev/null 2>&1; then
  cat /tmp/manifests/pr-rendered.yaml | kubeconform -strict -ignore-missing-schemas -summary
else
  echo "[Warning] kubeconform is not installed locally. Skipping schema check."
fi

echo "=== 3. Rendering base branch (${BASE_REF}) manifests ==="
TMP_BASE_REPO=$(mktemp -d)
trap 'rm -rf "${TMP_BASE_REPO}"' EXIT

git archive "${BASE_REF}" | tar -x -C "${TMP_BASE_REPO}"
(
  cd "${TMP_BASE_REPO}"
  python3 "${SCRIPT_DIR}/.github/scripts/render-manifests.py" /tmp/manifests/base-rendered.yaml
)

echo "=== 4. Manifest Diff (${BASE_REF} vs Local) ==="
git diff --color=always --no-index /tmp/manifests/base-rendered.yaml /tmp/manifests/pr-rendered.yaml || true
