#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest_dir="$repo_root/clusters/home/configs/external-secrets"
actual="$(mktemp)"
expected="$(mktemp)"
trap 'rm -f "$actual" "$expected"' EXIT

if ! awk '
  $0 == "      cache:" {
    if ((getline ttl) <= 0 || ttl != "        ttl: 30m") {
      exit 1
    }
    if ((getline max_size) <= 0 || max_size != "        maxSize: 100") {
      exit 1
    }
    found = 1
  }
  END {
    if (!found) {
      exit 1
    }
  }
' "$manifest_dir/secret-store.yaml"; then
  echo "1password-sdk must enable a 30m cache with maxSize 100" >&2
  exit 1
fi

awk '
  function reset_document() {
    kind = ""
    name = ""
    refresh_interval = ""
    in_metadata = 0
  }
  function emit_document() {
    if (kind != "ExternalSecret") {
      return
    }
    if (name == "" || refresh_interval == "") {
      print "ExternalSecret is missing metadata.name or spec.refreshInterval" > "/dev/stderr"
      failed = 1
      return
    }
    print name "=" refresh_interval
  }
  BEGIN {
    reset_document()
  }
  FNR == 1 && NR != 1 {
    emit_document()
    reset_document()
  }
  /^---[[:space:]]*$/ {
    emit_document()
    reset_document()
    next
  }
  /^kind: / {
    kind = substr($0, 7)
    next
  }
  $0 == "metadata:" {
    in_metadata = 1
    next
  }
  in_metadata && /^  name: / {
    name = substr($0, 9)
    next
  }
  in_metadata && /^[^[:space:]]/ {
    in_metadata = 0
  }
  /^  refreshInterval: / {
    refresh_interval = substr($0, 20)
  }
  END {
    emit_document()
    if (failed) {
      exit 1
    }
  }
' "$manifest_dir"/*.yaml | sort >"$actual"

cat >"$expected" <<'EOF'
alerts-external-secret=12h
bifrost-secret=12h31m
cloudflare-external-secret=13h2m
feed-reader-storage=13h33m
grafana-cloud-secret=14h4m
neon-s3-credentials=18h43m
nostr-config=14h35m
nostr-credentials=15h6m
nostr-storage=15h37m
obsidian-secret=16h8m
qnap-csi-plugin=16h39m
rclone-s3-credentials=17h10m
tailscale-secret=17h41m
tekton-secret=18h12m
EOF

if ! diff -u "$expected" "$actual"; then
  echo "ExternalSecret refresh intervals do not match the rate limit policy" >&2
  exit 1
fi

awk -F= '
  {
    if ($2 !~ /^[0-9]+h([0-9]+m)?$/) {
      print "invalid refresh interval for " $1 ": " $2 > "/dev/stderr"
      failed = 1
      next
    }
    split($2, parts, "h")
    hours = parts[1] + 0
    minutes = parts[2]
    sub(/m$/, "", minutes)
    total_minutes = (hours * 60) + (minutes + 0)
    if (total_minutes < 720) {
      print "refresh interval below 12h for " $1 ": " $2 > "/dev/stderr"
      failed = 1
    }
    if (seen[$2]++) {
      print "duplicate refresh interval: " $2 > "/dev/stderr"
      failed = 1
    }
  }
  END {
    if (NR != 14) {
      print "expected 14 ExternalSecrets, found " NR > "/dev/stderr"
      failed = 1
    }
    if (failed) {
      exit 1
    }
  }
' "$actual"
