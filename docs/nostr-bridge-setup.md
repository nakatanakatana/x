# Nostr Relay and Bridge Setup

These instructions assume an administrative workstation with `openssl`, `jq`, the 1Password CLI (`op`), and `kubectl` installed.
Sign in to `op` with an account that can read and write the `k8s` vault before proceeding.

## Register the Mastodon OAuth application

Create an application in the developer settings for the `nakatanakatana@mstdn.jp` account on `mstdn.jp`.
Use these values:

- Application name: `nostr-bridge`
- Redirect URI: `https://nostr-bridge.nakatanakatana.app/oauth/mastodon/callback`

Request these scopes:

- `profile`
- `read:accounts`
- `read:follows`
- `read:lists`
- `read:statuses`
- `read:notifications`

Record the Client ID and Client Secret.
The configured Client ID is `8arEwiI-CnRtHSukPgRc1yPz9EnZ54Qde4ibc2WTH6Q`; store the Client Secret only in 1Password.

## Generate secrets

Run the following shell commands in a single session.
Secret values are stored only in a permission-restricted temporary directory, which is also removed when the shell exits.

```bash
set -euo pipefail
umask 077
secret_dir=$(mktemp -d)
trap 'rm -rf -- "$secret_dir"' EXIT HUP INT TERM

# All three values decode to secrets that are exactly 32 bytes long.
openssl rand -base64 32 >"$secret_dir/master-seed"
openssl rand -base64 32 >"$secret_dir/oauth-encryption-key"
openssl rand -base64 32 >"$secret_dir/mastodon-oauth-encryption-key"

read -r -s -p 'Mastodon OAuth client secret: ' MASTODON_OAUTH_CLIENT_SECRET
printf '\n'
printf '%s' "$MASTODON_OAUTH_CLIENT_SECRET" >"$secret_dir/mastodon-oauth-client-secret"
unset MASTODON_OAUTH_CLIENT_SECRET

# Convert a P-256 private key to PKCS#8 DER and store it as single-line base64.
openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -out "$secret_dir/oauth-signing.pem"
openssl pkcs8 \
  -topk8 \
  -nocrypt \
  -in "$secret_dir/oauth-signing.pem" \
  -outform DER |
  openssl base64 -A >"$secret_dir/oauth-client-signing-key"

# Wrap a 32-byte candidate in SEC1 format and regenerate it until OpenSSL
# accepts it as a valid secp256k1 scalar. Keep the scalar itself as binary.
while :; do
  openssl rand 32 >"$secret_dir/relay-admin.scalar"
  {
    printf '\060\056\002\001\001\004\040'
    dd if="$secret_dir/relay-admin.scalar" bs=32 count=1 status=none
    printf '\240\007\006\005\053\201\004\000\012'
  } >"$secret_dir/relay-admin.sec1.der"
  if openssl pkey \
    -inform DER \
    -in "$secret_dir/relay-admin.sec1.der" \
    -noout \
    -check 2>/dev/null; then
    break
  fi
done

# A Nostr private key is the 32-byte scalar encoded as hexadecimal. Its public
# key is the 32-byte x-only public key, without the compressed-key prefix.
od -An -vtx1 "$secret_dir/relay-admin.scalar" |
  tr -d ' \n' >"$secret_dir/relay-admin-private-key"
openssl pkey \
  -inform DER \
  -in "$secret_dir/relay-admin.sec1.der" \
  -pubout \
  -outform DER >"$secret_dir/relay-admin-public.der"
test "$(tail -c 65 "$secret_dir/relay-admin-public.der" | head -c 1 | od -An -tu1 | tr -d ' ')" = 4
tail -c 64 "$secret_dir/relay-admin-public.der" |
  head -c 32 |
  od -An -vtx1 |
  tr -d ' \n' >"$secret_dir/relay-admin-public-key"

# Validate the generated formats without printing the secret values.
test "$(openssl base64 -d -A -in "$secret_dir/master-seed" | wc -c)" -eq 32
test "$(openssl base64 -d -A -in "$secret_dir/oauth-encryption-key" | wc -c)" -eq 32
test "$(openssl base64 -d -A -in "$secret_dir/mastodon-oauth-encryption-key" | wc -c)" -eq 32
test -s "$secret_dir/mastodon-oauth-client-secret"
test "$(wc -c <"$secret_dir/relay-admin-private-key")" -eq 64
test "$(wc -c <"$secret_dir/relay-admin-public-key")" -eq 64
openssl pkey \
  -inform DER \
  -in "$secret_dir/relay-admin.sec1.der" \
  -noout \
  -check >/dev/null
openssl base64 -d -A -in "$secret_dir/oauth-client-signing-key" |
  openssl pkey -inform DER -noout -check >/dev/null
```

## Register values in 1Password

Set `TAILNET_DOMAIN` to the tailnet DNS name shown in the Tailscale administration console.
The value is passed only through the command environment and is not written to a file.

The following commands create the `nostr-bridge` item if it does not exist, or update the existing item otherwise.
Secret values are passed to `op` through a temporary JSON document instead of being expanded into command-line arguments.

```bash
read -r -p 'Tailnet domain: ' TAILNET_DOMAIN
export TAILNET_DOMAIN

if op item get nostr-bridge --vault k8s --format json \
  >"$secret_dir/nostr-bridge-item.json" 2>/dev/null; then
  item_mode=edit
else
  item_mode=create
  op item template get Password >"$secret_dir/nostr-bridge-item.json"
fi

jq \
  --arg title 'nostr-bridge' \
  --arg tailnet "$TAILNET_DOMAIN" \
  --rawfile private "$secret_dir/relay-admin-private-key" \
  --rawfile public "$secret_dir/relay-admin-public-key" \
  --rawfile master "$secret_dir/master-seed" \
  --rawfile signing "$secret_dir/oauth-client-signing-key" \
  --rawfile encryption "$secret_dir/oauth-encryption-key" \
  --rawfile mastodon_client_secret "$secret_dir/mastodon-oauth-client-secret" \
  --rawfile mastodon_encryption "$secret_dir/mastodon-oauth-encryption-key" \
  '
    def put($label; $value):
      .fields = ((.fields // []) as $fields
        | if any($fields[]; .label == $label) then
            $fields | map(
              if .label == $label then
                .type = "CONCEALED"
                | .value = ($value | sub("\\n$"; ""))
              else . end
            )
          else
            $fields + [{
              "label": $label,
              "type": "CONCEALED",
              "value": ($value | sub("\\n$"; ""))
            }]
          end);
    .title = $title
    | put("tailnet-domain"; $tailnet)
    | put("relay-admin-private-key"; $private)
    | put("relay-admin-public-key"; $public)
    | put("master-seed"; $master)
    | put("oauth-client-signing-key"; $signing)
    | put("oauth-encryption-key"; $encryption)
    | put("mastodon-oauth-client-secret"; $mastodon_client_secret)
    | put("mastodon-oauth-encryption-key"; $mastodon_encryption)
  ' "$secret_dir/nostr-bridge-item.json" \
  >"$secret_dir/nostr-bridge-item.updated.json"

if [ "$item_mode" = create ]; then
  op item create \
    --vault k8s \
    --category Password \
    --template "$secret_dir/nostr-bridge-item.updated.json" >/dev/null
else
  op item edit nostr-bridge \
    --vault k8s \
    --template "$secret_dir/nostr-bridge-item.updated.json" >/dev/null
fi
unset TAILNET_DOMAIN
```

The resulting remote paths match `clusters/home/configs/external-secrets/nostr.yaml`:

- `nostr-bridge/tailnet-domain`
- `nostr-bridge/relay-admin-private-key`
- `nostr-bridge/relay-admin-public-key`
- `nostr-bridge/master-seed`
- `nostr-bridge/oauth-client-signing-key`
- `nostr-bridge/oauth-encryption-key`
- `nostr-bridge/mastodon-oauth-client-secret`
- `nostr-bridge/mastodon-oauth-encryption-key`

The storage credentials use the dedicated `nostr-storage/access_key` and `nostr-storage/access_secret` values.
Verify that the `nostr-storage` item and both fields are registered in the `k8s` vault.

After registration, explicitly remove the temporary directory and disable the cleanup trap.

```bash
rm -rf -- "$secret_dir"
trap - EXIT HUP INT TERM
unset secret_dir
```

## Prepare the S3-compatible storage

Create a `nostr` bucket in the existing S3-compatible storage.
The relay and bridge Litestream processes use separate prefixes in the same bucket, so changing the bucket name requires updating both Litestream configurations.

Grant the `nostr-storage` access key permission to read, write, and list objects in the `nostr` bucket.
Bucket creation commands vary by S3-compatible product; use the corresponding administration CLI or console.

## Synchronize secrets and authorize OAuth

After Flux reconciles the changes, verify ExternalSecret synchronization in the home cluster's `app` namespace.

```bash
kubectl -n app get externalsecret nostr-config nostr-credentials nostr-storage
kubectl -n app get secret nostr-config nostr-credentials nostr-storage
```

In the vcluster's `nostr` namespace, wait until the relay is Ready and the bridge Pod is Running.
First verify that the active `kubectl` context points to the vcluster.
The bridge `/readyz` endpoint requires an OAuth connection, so do not wait for the bridge rollout to finish at this stage.

```bash
kubectl config current-context
kubectl -n nostr rollout status deployment/nostr-relay --timeout=5m
kubectl -n nostr wait \
  --for=jsonpath='{.status.phase}'=Running \
  pod \
  -l app=nostr-bridge \
  --timeout=5m
curl --fail --silent --show-error \
  "https://nostr-bridge.<tailnet-domain>/healthz" >/dev/null
```

After confirming the relay and bridge process health, start Bluesky OAuth authorization from within the tailnet.
`/oauth/bluesky/start` accepts only `POST` requests and requires the target handle as JSON.
Do not save the complete response to a file; extract only the non-empty authorization URL into a shell variable.

```bash
authorization_url=$(
  curl --fail --silent --show-error \
    --request POST \
    --header 'Content-Type: application/json' \
    --data '{"handle":"nakatanakatana.dev"}' \
    "https://nostr-bridge.<tailnet-domain>/oauth/bluesky/start" |
    jq -er '.authorization_url | select(type == "string" and length > 0)'
)
printf '%s\n' "$authorization_url"
```

Open the displayed authorization URL in a browser connected to Tailscale.
Authorize `nakatanakatana.dev` on the Bluesky authorization page and verify that the `/oauth/bluesky/callback` callback reports success.
After passing the URL to the browser, run `unset authorization_url` so the value does not remain in the shell environment.
Run `/oauth/bluesky/start` only through the Tailscale Ingress.
The Cloudflare Ingress exposes `/oauth/bluesky/callback`, `/oauth/bluesky/client-metadata.json`, and `/oauth/bluesky/jwks`; it does not expose the authorization start endpoint.
The callback and client metadata URLs must use the same public origin, `https://nostr-bridge.nakatanakatana.app`.

When migrating from a bridge release that used the generic OAuth routes, complete Bluesky authorization again after deployment.
The migration adds an RPC scope, so refreshing the existing token is not sufficient.

After establishing the OAuth connection, verify the bridge rollout and Pod readiness.

```bash
kubectl -n nostr rollout status deployment/nostr-bridge --timeout=5m
kubectl -n nostr get pods
```

## Authorize Mastodon

After the Mastodon configuration and ExternalSecret changes have reconciled, verify that the new keys exist without printing their values.

```bash
kubectl -n app get externalsecret nostr-config nostr-credentials
kubectl -n app get secret nostr-config nostr-credentials
```

From within the tailnet, start Mastodon OAuth authorization.
`/oauth/mastodon/start` accepts only `POST` requests and must not be exposed through the Cloudflare Ingress.

```bash
authorization_url=$(
  curl --fail --silent --show-error \
    --request POST \
    "https://nostr-bridge.<tailnet-domain>/oauth/mastodon/start" |
    jq -er '.authorization_url | select(type == "string" and length > 0)'
)
printf '%s\n' "$authorization_url"
```

Open the displayed URL in a browser, sign in to `mstdn.jp` as `nakatanakatana@mstdn.jp`, and grant access.
The public callback is `https://nostr-bridge.nakatanakatana.app/oauth/mastodon/callback`.
Authorization is rejected if the authenticated account does not match `nakatanakatana@mstdn.jp`.
After passing the URL to the browser, run `unset authorization_url`.

Verify health, readiness, and metrics through the Tailscale Ingress, then inspect the bridge logs.

```bash
curl --fail --silent --show-error \
  "https://nostr-bridge.<tailnet-domain>/healthz" >/dev/null
curl --fail --silent --show-error \
  "https://nostr-bridge.<tailnet-domain>/readyz" >/dev/null
curl --fail --silent --show-error \
  "https://nostr-bridge.<tailnet-domain>/metrics" >/dev/null
kubectl -n nostr logs deployment/nostr-bridge -c nostr-bridge --follow
```

Confirm that authentication, initial reconciliation, and streaming succeed, and that the outbox does not remain at its limit.
Investigate repeated `authentication failed` or `initial reconciliation failed` messages.
Only public Mastodon posts are bridged; boosts, unlisted, private, and direct posts are excluded.
