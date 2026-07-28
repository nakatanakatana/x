# pCloud S3 Gateway Setup

## Endpoint and storage mapping

The gateway is available only inside the cluster:

`http://gateway.pcloud-s3.svc.cluster.local:8080`

The pCloud US-region directory `buckets/` is the served root. Each direct child directory is an S3 bucket.

## Create credentials

On a trusted workstation with a browser, run `rclone authorize pcloud`. Store the complete returned JSON object as `PCLOUD_TOKEN` in the `pcloud-s3` item of the `k8s` 1Password vault.

Generate and store independent S3 credentials:

```bash
openssl rand -hex 20
openssl rand -hex 32
```

Store the first result as `S3_ACCESS_KEY_ID` and the second as `S3_SECRET_ACCESS_KEY`. Do not commit or paste any of these values into Kubernetes manifests.

## Client configuration

Configure clients with:

- endpoint: `http://gateway.pcloud-s3.svc.cluster.local:8080`
- region: `us-east-1`
- path-style addressing: enabled
- AWS Signature Version 4: enabled
- multipart uploads: disabled where the client supports that option

## Reconciliation checks

After Flux applies the change, check resource status without decoding the Secret:

```bash
kubectl -n pcloud-s3 get externalsecret rclone-s3-credentials
diff -u \
  <(printf '%s\n' PCLOUD_TOKEN RCLONE_AUTH_KEY S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY | sort) \
  <(kubectl -n pcloud-s3 get secret rclone-s3-credentials \
    -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}' | sort)
kubectl -n pcloud-s3 get pvc rclone-s3-cache
kubectl -n pcloud-s3 rollout status deployment/rclone-s3-gateway
kubectl -n pcloud-s3 get service gateway
kubectl -n pcloud-s3 get endpointslice -l kubernetes.io/service-name=gateway
```

The Secret check prints and compares key names only. It never decodes or displays Secret values.

## Rotate credentials

Update the values in the `pcloud-s3` 1Password item. The Deployment receives credentials through environment variables, so running Pods do not see refreshed Secret values until they restart.

Capture the current ExternalSecret refresh time and request a new reconciliation. The initial read and annotation each have a 15-second API request timeout. The polling loop starts requests during a 10-minute window and requires both a new refresh time and `Ready=True`; a final request started just before the deadline can extend the wait by at most its 15-second request timeout. Only then restart the Deployment and wait for the bounded `Recreate` rollout:

```bash
set -euo pipefail

previous_refresh_time="$(
  kubectl -n pcloud-s3 --request-timeout=15s \
    get externalsecret rclone-s3-credentials \
    -o jsonpath='{.status.refreshTime}'
)"

kubectl -n pcloud-s3 --request-timeout=15s annotate \
  externalsecret/rclone-s3-credentials \
  force-sync="$(date +%s)" \
  --overwrite

refresh_deadline=$((SECONDS + 600))
current_refresh_time="$previous_refresh_time"
ready_status=""

while (( SECONDS < refresh_deadline )); do
  rotation_status="$(
    kubectl -n pcloud-s3 --request-timeout=15s \
      get externalsecret rclone-s3-credentials \
      -o jsonpath='{.status.refreshTime}{"|"}{.status.conditions[?(@.type=="Ready")].status}'
  )"
  current_refresh_time="${rotation_status%%|*}"
  ready_status="${rotation_status#*|}"

  if [[ -n "$current_refresh_time" \
    && "$current_refresh_time" != "$previous_refresh_time" \
    && "$ready_status" == "True" ]]; then
    break
  fi

  if (( SECONDS >= refresh_deadline )); then
    break
  fi

  sleep 5
done

if [[ -z "$current_refresh_time" \
  || "$current_refresh_time" == "$previous_refresh_time" \
  || "$ready_status" != "True" ]]; then
  printf '%s\n' 'Timed out waiting for refreshed ExternalSecret credentials' >&2
  exit 1
fi

kubectl -n pcloud-s3 --request-timeout=15s \
  rollout restart deployment/rclone-s3-gateway
kubectl -n pcloud-s3 --request-timeout=10m \
  rollout status deployment/rclone-s3-gateway --timeout=10m
```

Every Kubernetes API request in this procedure has a finite request timeout. The rollout status command also has a 10-minute rollout timeout. These commands inspect only ExternalSecret status fields and never print Secret values. Because the Deployment uses `Recreate`, the old Pod terminates before the replacement starts with the refreshed environment variables.

## Smoke test

After reconciliation, the platform operator must explicitly notify the S3 test operator that reconciliation is complete. The S3 test operator must wait for that confirmation before running any mutating CRUD test. After receiving it, the S3 test operator will run an authenticated CRUD test from inside the cluster using a uniquely named temporary bucket, confirm that incorrect credentials are rejected, verify pCloud visibility, and remove only the temporary test data.

## Teardown

The Namespace and cache PVC disable Flux pruning so an accidental Git removal cannot discard pending writes. Before intentional teardown, stop all clients and verify that every accepted write is present in pCloud and that the gateway logs show no failed, retrying, or in-progress uploads. Do not delete the cache while any write is pending.

After removing the gateway manifests from Git and waiting for Flux to prune the unprotected workload resources, manually delete the protected resources:

```bash
kubectl -n pcloud-s3 delete pvc rclone-s3-cache
kubectl delete namespace pcloud-s3
```

## Limitations

`rclone serve s3` is experimental. It does not support S3 versioning, stores multipart upload parts in memory, and does not support multipart server-side copies. Read-only object data bypasses the PVC; the PVC stores write-back cache data.
