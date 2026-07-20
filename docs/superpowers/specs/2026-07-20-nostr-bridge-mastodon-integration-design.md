# Nostr Bridge Mastodon Integration Design

## Goal

Enable the existing `nostr-bridge` v0.6.0 deployment to ingest the Home timeline and followed accounts for `nakatanakatana@mstdn.jp` while preserving the current Bluesky integration and Nostr identity.

## Provider Configuration

Configure the Mastodon provider with these fixed values:

| Setting | Value |
| --- | --- |
| Base URL | `https://mstdn.jp` |
| Account | `nakatanakatana@mstdn.jp` |
| OAuth callback | `https://nostr-bridge.nakatanakatana.app/oauth/mastodon/callback` |
| OAuth client ID | `8arEwiI-CnRtHSukPgRc1yPz9EnZ54Qde4ibc2WTH6Q` |

Do not set `NOSTR_BRIDGE_MASTODON_LIST_IDS`; only the Home timeline and followed accounts are in scope. Do not set `NOSTR_BRIDGE_MASTODON_BACKFILL_LIMIT` or `NOSTR_BRIDGE_MASTODON_RECONCILE_INTERVAL`; use the application defaults.

Keep `NOSTR_BRIDGE_OWNER_ID=nakatanakatana-bridge`, the existing SQLite PVC, master seed, relay configuration, and all Bluesky settings unchanged. This preserves the common Nostr owner and the deterministic per-source Nostr identities.

## Secret Management

Extend the existing `nostr-credentials` ExternalSecret rather than creating a provider-specific Kubernetes Secret. Add these Secret keys and map them to the corresponding properties in the `k8s` vault's `nostr-bridge` item:

| Kubernetes Secret key | 1Password remote path |
| --- | --- |
| `mastodon-oauth-client-secret` | `nostr-bridge/mastodon-oauth-client-secret` |
| `mastodon-oauth-encryption-key` | `nostr-bridge/mastodon-oauth-encryption-key` |

The properties already exist in 1Password. Never place either value in Git, command output, or the Deployment manifest. The encryption key must remain stable so persisted Mastodon OAuth tokens remain decryptable.

Extend the existing `nostr-config` Secret template with a non-sensitive `mastodon-callback-url` value. The Deployment consumes the callback through this Secret key, following the existing Bluesky callback pattern.

## Deployment and Routing

Add the six required Mastodon environment variables to the `nostr-bridge` container:

- `NOSTR_BRIDGE_MASTODON_BASE_URL`
- `NOSTR_BRIDGE_MASTODON_ACCOUNT`
- `NOSTR_BRIDGE_MASTODON_OAUTH_CALLBACK_URL`
- `NOSTR_BRIDGE_MASTODON_OAUTH_CLIENT_ID`
- `NOSTR_BRIDGE_MASTODON_OAUTH_CLIENT_SECRET`
- `NOSTR_BRIDGE_MASTODON_OAUTH_ENCRYPTION_KEY`

Expose only `/oauth/mastodon/callback` through the existing Cloudflare Ingress. The Tailscale Ingress already routes all paths and remains the only entry point for `POST /oauth/mastodon/start`, `/healthz`, `/readyz`, and `/metrics`.

The Mastodon application registration must use the exact public callback URL and request these scopes:

- `profile`
- `read:accounts`
- `read:follows`
- `read:lists`
- `read:statuses`
- `read:notifications`

## Operating Procedure

Extend `docs/nostr-bridge-setup.md` with:

1. Mastodon application registration values and scopes.
2. Generation and 1Password storage of the 32-byte Mastodon OAuth encryption key.
3. ExternalSecret synchronization checks for the new keys without printing their values.
4. Deployment readiness expectations while Mastodon authorization is absent.
5. A Tailscale-only `POST /oauth/mastodon/start` command that extracts only `authorization_url`.
6. Browser authorization and callback completion checks.
7. Health, readiness, metrics, and log checks after authorization.
8. The supported visibility behavior: only public posts are bridged; boosts, unlisted, private, and direct posts are excluded.

## Failure Handling

The bridge may remain Not Ready after rollout until Mastodon OAuth succeeds. If authorization uses an account other than `nakatanakatana@mstdn.jp`, the callback must be treated as rejected. Operators should inspect logs for repeated authentication, initial reconciliation, streaming, or outbox failures before considering rollout complete.

Existing Bluesky authorization must not be repeated solely because Mastodon configuration is added.

## Verification

Before publishing the change:

1. Render `clusters/vcluster-app` successfully with Kustomize.
2. Verify all six Mastodon variables and their exact non-secret values or Secret references in rendered output.
3. Verify the two new ExternalSecret remote paths and the callback template key.
4. Verify `/oauth/mastodon/callback` is present in the Cloudflare Ingress.
5. Verify `/oauth/mastodon/start`, `/healthz`, `/readyz`, and `/metrics` are not explicitly added to the Cloudflare Ingress.
6. Verify no secret value is present in the Git diff.
7. Verify the existing Bluesky variables, owner ID, database path, and bridge image are unchanged.
8. Run `git diff --check` and inspect the complete staged diff before committing.
