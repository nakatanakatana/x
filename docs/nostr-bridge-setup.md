# Nostr Relay and Bridge Setup

These instructions assume an administrative workstation with `openssl`, `jq`, the 1Password CLI (`op`), and `kubectl` installed.
Sign in to `op` with an account that can read and write the `k8s` vault before proceeding.

## Generate secrets

Run the following shell commands in a single session.
Secret values are stored only in a permission-restricted temporary directory, which is also removed when the shell exits.

```bash
set -euo pipefail
umask 077
secret_dir=$(mktemp -d)
trap 'rm -rf -- "$secret_dir"' EXIT HUP INT TERM

# Both values decode to seeds that are exactly 32 bytes long.
openssl rand -base64 32 >"$secret_dir/master-seed"
openssl rand -base64 32 >"$secret_dir/oauth-encryption-key"

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
The Cloudflare Ingress exposes only `/oauth/bluesky/client-metadata.json` and `/oauth/bluesky/jwks`; it does not expose the authorization start or callback endpoints.

When migrating from a bridge release that used the generic OAuth routes, complete Bluesky authorization again after deployment.
The migration adds an RPC scope, so refreshing the existing token is not sufficient.

After establishing the OAuth connection, verify the bridge rollout and Pod readiness.

```bash
kubectl -n nostr rollout status deployment/nostr-bridge --timeout=5m
kubectl -n nostr get pods
```
