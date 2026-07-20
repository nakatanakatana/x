# Nostr Bridge Mastodon Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure `nostr-bridge` to connect `nakatanakatana@mstdn.jp` to the existing common Nostr owner while preserving the Bluesky integration.

**Architecture:** Extend the existing ExternalSecrets and bridge Deployment instead of introducing provider-specific Kubernetes resources. Publish only the Mastodon OAuth callback through Cloudflare, keep authorization start and operational endpoints on Tailscale, and document secret registration and OAuth operation.

**Tech Stack:** Kubernetes YAML, External Secrets Operator, Kustomize, Markdown, shell assertions with `rg`

## Global Constraints

- Use Mastodon base URL `https://mstdn.jp`.
- Use account `nakatanakatana@mstdn.jp`.
- Use callback `https://nostr-bridge.nakatanakatana.app/oauth/mastodon/callback`.
- Use client ID `8arEwiI-CnRtHSukPgRc1yPz9EnZ54Qde4ibc2WTH6Q`.
- Read the Client Secret and encryption key only from the existing `nostr-credentials` Secret.
- Do not configure list IDs, backfill limit, or reconcile interval.
- Do not expose OAuth start, health, readiness, or metrics through Cloudflare.
- Preserve the existing image, SQLite path and PVC, owner ID, master seed, relay settings, and Bluesky configuration.

---

### Task 1: Add Mastodon ExternalSecret mappings

**Files:**
- Modify: `clusters/home/configs/external-secrets/nostr.yaml`

**Interfaces:**
- Consumes: `nostr-bridge/mastodon-oauth-client-secret` and `nostr-bridge/mastodon-oauth-encryption-key` from 1Password.
- Produces: `nostr-config/mastodon-callback-url` and two new keys in `nostr-credentials`.

- [ ] **Step 1: Verify the new Secret mappings are absent**

```bash
set +e
rg -q 'mastodon-callback-url' clusters/home/configs/external-secrets/nostr.yaml
test "$?" -eq 1
rg -q 'mastodon-oauth-client-secret' clusters/home/configs/external-secrets/nostr.yaml
test "$?" -eq 1
rg -q 'mastodon-oauth-encryption-key' clusters/home/configs/external-secrets/nostr.yaml
test "$?" -eq 1
```

Expected: all three searches are absent.

- [ ] **Step 2: Add the callback template and credential mappings**

Add this template entry to `nostr-config`:

```yaml
mastodon-callback-url: "https://nostr-bridge.nakatanakatana.app/oauth/mastodon/callback"
```

Add these entries to `nostr-credentials.spec.data`:

```yaml
- secretKey: mastodon-oauth-client-secret
  remoteRef:
    key: nostr-bridge/mastodon-oauth-client-secret
- secretKey: mastodon-oauth-encryption-key
  remoteRef:
    key: nostr-bridge/mastodon-oauth-encryption-key
```

- [ ] **Step 3: Verify the exact mappings are present**

```bash
rg -q -F 'mastodon-callback-url: "https://nostr-bridge.nakatanakatana.app/oauth/mastodon/callback"' clusters/home/configs/external-secrets/nostr.yaml
rg -q -U -- '- secretKey: mastodon-oauth-client-secret\n[[:space:]]+remoteRef:\n[[:space:]]+key: nostr-bridge/mastodon-oauth-client-secret' clusters/home/configs/external-secrets/nostr.yaml
rg -q -U -- '- secretKey: mastodon-oauth-encryption-key\n[[:space:]]+remoteRef:\n[[:space:]]+key: nostr-bridge/mastodon-oauth-encryption-key' clusters/home/configs/external-secrets/nostr.yaml
```

Expected: PASS.

### Task 2: Configure the Mastodon provider and callback route

**Files:**
- Modify: `clusters/vcluster-app/nostr/bridge.yaml`

**Interfaces:**
- Consumes: The new `nostr-config` and `nostr-credentials` keys from Task 1.
- Produces: The six required Mastodon environment variables and public callback route.

- [ ] **Step 1: Verify the Mastodon provider configuration is absent**

```bash
set +e
rg -q 'NOSTR_BRIDGE_MASTODON_BASE_URL' clusters/vcluster-app/nostr/bridge.yaml
test "$?" -eq 1
rg -q 'path: /oauth/mastodon/callback' clusters/vcluster-app/nostr/bridge.yaml
test "$?" -eq 1
```

Expected: both searches are absent.

- [ ] **Step 2: Add the required environment variables**

Add the base URL, account, callback Secret reference, client ID, Client Secret reference, and encryption key reference. Do not add optional Mastodon variables.

- [ ] **Step 3: Add only the public callback route**

Add `/oauth/mastodon/callback` to `nostr-bridge-cloudflare`, routed to service `nostr-bridge` port `8080`.

- [ ] **Step 4: Render and verify the Deployment and Ingress**

```bash
rendered_file=$(mktemp)
trap 'rm -f "$rendered_file"' EXIT
kustomize build clusters/vcluster-app >"$rendered_file"
for variable in NOSTR_BRIDGE_MASTODON_BASE_URL NOSTR_BRIDGE_MASTODON_ACCOUNT NOSTR_BRIDGE_MASTODON_OAUTH_CALLBACK_URL NOSTR_BRIDGE_MASTODON_OAUTH_CLIENT_ID NOSTR_BRIDGE_MASTODON_OAUTH_CLIENT_SECRET NOSTR_BRIDGE_MASTODON_OAUTH_ENCRYPTION_KEY; do
  rg -q -- "- name: $variable" "$rendered_file"
done
rg -q -F 'value: https://mstdn.jp' "$rendered_file"
rg -q -F 'value: nakatanakatana@mstdn.jp' "$rendered_file"
rg -q -F 'value: 8arEwiI-CnRtHSukPgRc1yPz9EnZ54Qde4ibc2WTH6Q' "$rendered_file"
rg -q -F 'path: /oauth/mastodon/callback' "$rendered_file"
if rg -n 'path: /oauth/mastodon/(start|healthz|readyz|metrics)' "$rendered_file"; then exit 1; fi
```

Expected: PASS.

### Task 3: Document Mastodon registration and OAuth operation

**Files:**
- Modify: `docs/nostr-bridge-setup.md`

**Interfaces:**
- Consumes: The callback, account, scopes, and Secret paths configured in Tasks 1 and 2.
- Produces: A reproducible setup and verification procedure that never prints secret values.

- [ ] **Step 1: Verify Mastodon instructions are absent**

```bash
set +e
rg -q '/oauth/mastodon/start' docs/nostr-bridge-setup.md
test "$?" -eq 1
rg -q 'mastodon-oauth-client-secret' docs/nostr-bridge-setup.md
test "$?" -eq 1
```

Expected: both searches are absent.

- [ ] **Step 2: Extend secret generation and registration**

Document generation of the 32-byte encryption key, safe registration of both Mastodon secret values in the existing 1Password item, and the resulting remote paths.

- [ ] **Step 3: Add application registration and OAuth operation**

Document the exact callback, required scopes, Tailscale-only authorization request, browser callback, readiness and metrics checks, relevant log failure patterns, and public-post-only behavior.

- [ ] **Step 4: Verify documentation coverage**

```bash
for text in '/oauth/mastodon/start' '/oauth/mastodon/callback' 'mastodon-oauth-client-secret' 'mastodon-oauth-encryption-key' 'read:notifications' 'nakatanakatana@mstdn.jp'; do
  rg -q -F "$text" docs/nostr-bridge-setup.md
done
```

Expected: PASS.

### Task 4: Verify, commit, publish, and monitor

**Files:**
- Verify all files changed by Tasks 1-3 and the design/plan documents.

**Interfaces:**
- Consumes: The complete Mastodon integration change.
- Produces: A reviewed draft pull request with all checks in terminal state.

- [ ] **Step 1: Run fresh full verification**

```bash
kustomize build clusters/vcluster-app >/tmp/nostr-bridge-mastodon-rendered.yaml
git diff --check origin/main...HEAD
git diff --check
git status -sb
```

Expected: Kustomize succeeds and no whitespace errors are reported.

- [ ] **Step 2: Inspect and stage only intended files**

```bash
git diff --stat origin/main
git diff origin/main -- clusters/home/configs/external-secrets/nostr.yaml clusters/vcluster-app/nostr/bridge.yaml docs/nostr-bridge-setup.md docs/superpowers
git add clusters/home/configs/external-secrets/nostr.yaml clusters/vcluster-app/nostr/bridge.yaml docs/nostr-bridge-setup.md docs/superpowers
git diff --cached --check
```

Expected: only the Mastodon integration files are staged.

- [ ] **Step 3: Commit and push**

```bash
git commit -m "Add Mastodon support to nostr-bridge"
git push -u origin agent/add-nostr-bridge-mastodon
```

- [ ] **Step 4: Create a draft PR and monitor every check**

Create a draft PR titled `Add Mastodon support to nostr-bridge`. Monitor Actions runs, check runs, and commit statuses until none are pending. Inspect and fix any in-scope failure before reporting completion.

- [ ] **Step 5: Remove temporary rendered output**

```bash
rm -f /tmp/nostr-bridge-mastodon-rendered.yaml
```
