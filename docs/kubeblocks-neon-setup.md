# KubeBlocks Neon の運用手順

この手順は、`database` Namespace の `Cluster/neon-demo` を対象にする。

KubeBlocks 本体と Neon addon は、`kb-system` Namespace の `HelmRelease/kubeblocks` と `HelmRelease/neon` が提供する。

pageserver の remote storage は `http://gateway.pcloud-s3.svc.cluster.local:8080` である。

remote bucket は `neon-demo`、リージョンは `us-east-1` であり、path-style addressing を使う。

以下のコードブロックは、信頼できる管理端末の同じ対話シェルで順に実行する。

共有ログ、CI、画面共有、シェルの `xtrace` が有効な端末では、認証情報を取得するコードブロックを実行しない。

すべての `kubectl` 要求には有限の `--request-timeout` を指定している。

待機処理は期限内に条件を満たさなければ失敗として停止する。

## 導入状態の確認

はじめに、二つの HelmRelease の Ready 条件を確認する。

```bash
set -euo pipefail

for release in kubeblocks neon; do
  ready_status="$(
    kubectl -n kb-system --request-timeout=15s \
      get helmrelease/"$release" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  )"

  if [[ "$ready_status" != "True" ]]; then
    printf 'HelmRelease/%s is not Ready: %s\n' "$release" "$ready_status" >&2
    exit 1
  fi
done
```

次に、Cluster の状態と終了ポリシーを確認する。

```bash
kubectl -n database --request-timeout=15s \
  get cluster/neon-demo \
  -o jsonpath='{.metadata.name}{" phase="}{.status.phase}{" terminationPolicy="}{.spec.terminationPolicy}{"\n"}'
```

Cluster の phase が `Running`、`terminationPolicy` が `Delete` であることを確認する。

生成済みの Pod、PVC、Service と gateway の接続先も確認する。

```bash
kubectl -n database --request-timeout=15s get pods
kubectl -n database --request-timeout=15s get pvc
kubectl -n database --request-timeout=15s get services
kubectl -n pcloud-s3 --request-timeout=15s \
  get endpointslice -l kubernetes.io/service-name=gateway
```

`gateway` は `pcloud-s3` Namespace の `app=rclone-s3-gateway` Pod を選択する ClusterIP Service である。

`neon-s3-credentials` のキー名を確認する。

```bash
kubectl -n database --request-timeout=15s \
  get secret/neon-s3-credentials \
  -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}' |
  sort
```

出力には `AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` が含まれる。

gateway の `rclone-s3-credentials` も同じ方法で確認する。

```bash
kubectl -n pcloud-s3 --request-timeout=15s \
  get secret/rclone-s3-credentials \
  -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}' |
  sort
```

出力には `PCLOUD_TOKEN`、`RCLONE_AUTH_KEY`、`S3_ACCESS_KEY_ID`、`S3_SECRET_ACCESS_KEY` が含まれる。

これらのコマンドは Secret のキー名だけを表示し、値を表示しない。

Neon chart は `cloud_admin` system account を定義するが、KubeBlocks が生成する接続用 Secret の完全名はマニフェストに固定されていない。

そこで、Cluster と component の label で候補を限定し、現在の `metadata.name` から account 名に対応する Secret を一つだけ選ぶ。

```bash
cluster_name=neon-demo
compute_component_name=neon-compute
compute_resource_name="${cluster_name}-${compute_component_name}"
account_selector="app.kubernetes.io/instance=${cluster_name},apps.kubeblocks.io/component-name=${compute_component_name}"

mapfile -t account_secrets < <(
  kubectl -n database --request-timeout=15s \
    get secrets -l "$account_selector" \
    -o go-template='{{range .items}}{{printf "%s\n" .metadata.name}}{{end}}' |
    awk '/-account-cloud-admin$/'
)

if (( ${#account_secrets[@]} != 1 )); then
  printf 'Expected one cloud_admin account Secret, found %s\n' \
    "${#account_secrets[@]}" >&2
  exit 1
fi

credential_secret="${account_secrets[0]}"

credential_owner_refs="$(
  kubectl -n database --request-timeout=15s \
    get secret/"$credential_secret" \
    -o go-template='{{range .metadata.ownerReferences}}{{printf "%s/%s\n" .kind .name}}{{end}}'
)"

if [[ $'\n'"$credential_owner_refs"$'\n' != \
  *$'\n'"Component/${compute_resource_name}"$'\n'* ]]; then
  printf '%s\n' \
    'The cloud_admin Secret is not owned by the neon-compute Component' >&2
  exit 1
fi

kubectl -n database --request-timeout=15s \
  get secret/"$credential_secret" \
  -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}' |
  sort
```

接続用 Secret の出力には `username` と `password` が含まれる。

候補は `Cluster/neon-demo` と `neon-compute` component の label を持ち、`Component/neon-demo-neon-compute` が ownerReference に設定されている場合に限り採用する。

探索と確認で扱うのは Secret の metadata とキー名だけであり、値は表示しない。

## cloud_admin 認証情報の対話的な取得

次のコードは、認証情報を現在の対話シェルの変数へ格納し、値を表示せずに account 名と空値だけを検査する。

```bash
set +x

db_user="$(
  kubectl -n database --request-timeout=15s \
    get secret/"$credential_secret" \
    -o jsonpath='{.data.username}' |
    base64 --decode
)"
db_password="$(
  kubectl -n database --request-timeout=15s \
    get secret/"$credential_secret" \
    -o jsonpath='{.data.password}' |
    base64 --decode
)"

if [[ "$db_user" != "cloud_admin" || -z "$db_password" ]]; then
  unset db_user db_password credential_secret credential_owner_refs \
    account_secrets account_selector cluster_name compute_component_name \
    compute_resource_name
  printf '%s\n' 'The generated cloud_admin credentials are invalid' >&2
  exit 1
fi

printf '%s\n' 'The cloud_admin credentials were loaded without printing their values'
unset db_user db_password credential_secret credential_owner_refs \
  account_secrets account_selector cluster_name compute_component_name \
  compute_resource_name
```

認証情報を `echo`、`printf`、ログ出力へ渡さず、Secret 全体を `-o yaml`、`-o json`、`describe` で表示しない。

後続の PostgreSQL 操作は compute コンテナへ注入済みの `PGUSER` と `PGPASSWORD` を使うため、ローカル変数へ取得した値をコマンド引数へ渡さない。

## PostgreSQL のスモークテスト

KubeBlocks の instance label と Cluster に定義した component 名から、compute Pod を一つだけ選ぶ。

```bash
mapfile -t compute_pods < <(
  kubectl -n database --request-timeout=15s \
    get pods \
    -l 'app.kubernetes.io/instance=neon-demo,apps.kubeblocks.io/component-name=neon-compute' \
    -o name
)

if (( ${#compute_pods[@]} != 1 )); then
  printf 'Expected one neon-compute Pod, found %s\n' \
    "${#compute_pods[@]}" >&2
  exit 1
fi

compute_pod="${compute_pods[0]#pod/}"
run_id="$(date -u +%Y%m%d%H%M%S)_$$_${RANDOM}"
table_name="neon_smoke_${run_id}"
expected_value="neon-smoke-${run_id}"
```

一意なテーブルを作成し、一行を挿入して同じ値を読み取る。

```bash
actual_value="$(
  kubectl -n database --request-timeout=30s \
    exec -i "$compute_pod" -c neon-compute -- \
    psql -XAtq -h 127.0.0.1 -d postgres \
      -v ON_ERROR_STOP=1 \
      -v table_name="$table_name" \
      -v expected_value="$expected_value" <<'SQL'
CREATE TABLE :"table_name" (value text NOT NULL);
INSERT INTO :"table_name" (value) VALUES (:'expected_value');
SELECT value FROM :"table_name";
SQL
)"

if [[ "$actual_value" != "$expected_value" ]]; then
  printf 'Unexpected smoke-test value: %s\n' "$actual_value" >&2
  exit 1
fi
```

再起動試験と障害復旧試験でも同じ行を検査するため、teardown までテーブルを削除しない。

後続の読み取りには、次の期限付き要求を使う。

```bash
read_smoke_value() {
  local actual_value

  actual_value="$(
    kubectl -n database --request-timeout=30s \
      exec -i "$compute_pod" -c neon-compute -- \
      psql -XAtq -h 127.0.0.1 -d postgres \
        -v ON_ERROR_STOP=1 \
        -v table_name="$table_name" <<'SQL'
SELECT value FROM :"table_name";
SQL
  )"

  if [[ "$actual_value" != "$expected_value" ]]; then
    printf 'Unexpected smoke-test value: %s\n' "$actual_value" >&2
    return 1
  fi
}
```

## pCloud 上のオブジェクト確認

gateway Pod の rclone 設定は、Pod に注入された環境変数から pCloud を認証する。

次の関数は Pod 名を label から取得する。

```bash
get_gateway_pod() {
  local -a gateway_pods

  mapfile -t gateway_pods < <(
    kubectl -n pcloud-s3 --request-timeout=15s \
      get pods -l app=rclone-s3-gateway -o name
  )

  if (( ${#gateway_pods[@]} != 1 )); then
    printf 'Expected one rclone gateway Pod, found %s\n' \
      "${#gateway_pods[@]}" >&2
    return 1
  fi

  printf '%s\n' "${gateway_pods[0]#pod/}"
}
```

remote bucket にオブジェクトが現れるまで最大 10 分待つ。

```bash
gateway_pod="$(get_gateway_pod)"
object_deadline=$((SECONDS + 600))
first_object=""

while (( SECONDS < object_deadline )); do
  if first_object="$(
    kubectl -n pcloud-s3 --request-timeout=30s \
      exec "$gateway_pod" -c rclone -- \
      sh -c 'rclone lsf pcloud:buckets/neon-demo --recursive | head -n 1'
  )" && [[ -n "$first_object" ]]; then
    break
  fi

  if (( SECONDS >= object_deadline )); then
    break
  fi

  sleep 5
done

if [[ -z "$first_object" ]]; then
  printf '%s\n' \
    'Timed out waiting for Neon objects in the neon-demo bucket' >&2
  exit 1
fi

printf '%s\n' "$first_object"
```

再帰的な列挙は最初の一件で停止する。

出力は一つのオブジェクト名だけであり、pCloud token や S3 認証情報を含まない。

## pageserver 再起動後の読み取り

次の関数は、現在の pageserver Pod を label から選択して削除し、同じ名前の replacement Pod が Ready になるまで最大 10 分待つ。

```bash
restart_pageserver() {
  local -a pageserver_pods
  local pageserver_pod
  local restart_deadline
  local ready_status

  mapfile -t pageserver_pods < <(
    kubectl -n database --request-timeout=15s \
      get pods \
      -l 'app.kubernetes.io/instance=neon-demo,apps.kubeblocks.io/component-name=neon-pageserver' \
      -o name
  )

  if (( ${#pageserver_pods[@]} != 1 )); then
    printf 'Expected one neon-pageserver Pod, found %s\n' \
      "${#pageserver_pods[@]}" >&2
    return 1
  fi

  pageserver_pod="${pageserver_pods[0]#pod/}"

  kubectl -n database --request-timeout=2m \
    delete pod/"$pageserver_pod" --wait=true --timeout=2m

  restart_deadline=$((SECONDS + 600))
  ready_status=""

  while (( SECONDS < restart_deadline )); do
    if ready_status="$(
      kubectl -n database --request-timeout=15s \
        get pod/"$pageserver_pod" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null
    )" && [[ "$ready_status" == "True" ]]; then
      break
    fi

    if (( SECONDS >= restart_deadline )); then
      break
    fi

    sleep 5
  done

  if [[ "$ready_status" != "True" ]]; then
    printf '%s\n' 'Timed out waiting for the replacement pageserver Pod' >&2
    return 1
  fi
}
```

pageserver を再起動し、保存した値を読み直す。

```bash
restart_pageserver
read_smoke_value
```

## gateway 停止中の挙動と復旧

この試験中は書き込みを行わない。

write-back cache を使う gateway の停止中に、新しい書き込みの永続性を仮定できないためである。

異常終了時にも gateway を 1 replica へ戻す cleanup を登録してから、Deployment を 0 replica へ縮退する。

```bash
restore_gateway() {
  kubectl -n pcloud-s3 --request-timeout=15s \
    scale deployment/rclone-s3-gateway --replicas=1
  kubectl -n pcloud-s3 --request-timeout=10m \
    rollout status deployment/rclone-s3-gateway --timeout=10m
}

gateway_restored=false

cleanup_gateway() {
  if [[ "$gateway_restored" != "true" ]]; then
    restore_gateway || true
  fi
}

trap cleanup_gateway EXIT INT TERM

kubectl -n pcloud-s3 --request-timeout=15s \
  scale deployment/rclone-s3-gateway --replicas=0
kubectl -n pcloud-s3 --request-timeout=5m \
  rollout status deployment/rclone-s3-gateway --timeout=5m
```

既存テーブルを読む試行の終了状態と出力をローカルファイルへ記録する。

```bash
outage_log="neon-gateway-outage-${run_id}.log"

set +e
kubectl -n database --request-timeout=30s \
  exec -i "$compute_pod" -c neon-compute -- \
  psql -XAtq -h 127.0.0.1 -d postgres \
    -v ON_ERROR_STOP=1 \
    -v table_name="$table_name" <<'SQL' >"$outage_log" 2>&1
SELECT value FROM :"table_name";
SQL
outage_status=$?
set -e

printf 'gateway-outage exit status: %s\n' "$outage_status" |
  tee -a "$outage_log"
```

キャッシュ済みの read が成功する場合と、remote storage へ到達できず失敗する場合がある。

いずれの結果も `outage_log` と終了状態を障害記録に残す。

この一回の観察だけでデータ損失の有無を判断しない。

gateway を復旧し、read を再試行する。

```bash
restore_gateway
gateway_restored=true
trap - EXIT INT TERM

kubectl -n pcloud-s3 --request-timeout=15s \
  get endpointslice -l kubernetes.io/service-name=gateway

if ! read_smoke_value; then
  restart_pageserver
  read_smoke_value
fi
```

## S3 認証情報のローテーション

先に 1Password の `pcloud-s3` 項目で `S3_ACCESS_KEY_ID` と `S3_SECRET_ACCESS_KEY` を更新する。

更新値を端末、Git、外部ログへ出力しない。

gateway と pageserver は認証情報を環境変数として読むため、両 Namespace の ExternalSecret を同期してから両方を再起動する。

次の関数は、同期前の refresh time を保存し、新しい refresh time と `Ready=True` を確認するまで最大 10 分待つ。

```bash
refresh_external_secret() {
  local namespace="$1"
  local name="$2"
  local previous_refresh_time
  local current_refresh_time
  local ready_status
  local rotation_status
  local refresh_deadline

  previous_refresh_time="$(
    kubectl -n "$namespace" --request-timeout=15s \
      get externalsecret/"$name" \
      -o jsonpath='{.status.refreshTime}'
  )"

  kubectl -n "$namespace" --request-timeout=15s \
    annotate externalsecret/"$name" \
    force-sync="$(date +%s%N)" --overwrite

  refresh_deadline=$((SECONDS + 600))
  current_refresh_time="$previous_refresh_time"
  ready_status=""

  while (( SECONDS < refresh_deadline )); do
    if rotation_status="$(
      kubectl -n "$namespace" --request-timeout=15s \
        get externalsecret/"$name" \
        -o jsonpath='{.status.refreshTime}{"|"}{.status.conditions[?(@.type=="Ready")].status}'
    )"; then
      current_refresh_time="${rotation_status%%|*}"
      ready_status="${rotation_status#*|}"

      if [[ -n "$current_refresh_time" \
        && "$current_refresh_time" != "$previous_refresh_time" \
        && "$ready_status" == "True" ]]; then
        break
      fi
    fi

    if (( SECONDS >= refresh_deadline )); then
      break
    fi

    sleep 5
  done

  if [[ -z "$current_refresh_time" \
    || "$current_refresh_time" == "$previous_refresh_time" \
    || "$ready_status" != "True" ]]; then
    printf 'Timed out waiting for ExternalSecret/%s in %s\n' \
      "$name" "$namespace" >&2
    return 1
  fi
}
```

両方の同期を確認して gateway と pageserver を再起動し、保存済みの値を読む。

```bash
refresh_external_secret pcloud-s3 rclone-s3-credentials
refresh_external_secret database neon-s3-credentials

kubectl -n pcloud-s3 --request-timeout=15s \
  rollout restart deployment/rclone-s3-gateway
kubectl -n pcloud-s3 --request-timeout=10m \
  rollout status deployment/rclone-s3-gateway --timeout=10m

restart_pageserver
read_smoke_value
```

状態確認では ExternalSecret の時刻と条件だけを読み、Secret の値を表示しない。

## Cluster の削除と remote bucket の保持

Flux が `clusters/home/resources/neon-demo.yaml` を管理している間に Cluster だけを削除すると、次回の reconcile で再作成される。

最初に稼働中の終了ポリシーを検査し、削除対象の PVC 名を保存する。

```bash
policy="$(
  kubectl -n database --request-timeout=15s \
    get cluster/neon-demo -o jsonpath='{.spec.terminationPolicy}'
)"

if [[ "$policy" != "Delete" ]]; then
  printf 'Refusing teardown: expected terminationPolicy Delete, got %s\n' \
    "$policy" >&2
  exit 1
fi

mapfile -t neon_pvcs < <(
  kubectl -n database --request-timeout=15s \
    get pvc -l app.kubernetes.io/instance=neon-demo -o name
)

if (( ${#neon_pvcs[@]} == 0 )); then
  printf '%s\n' 'No neon-demo PVCs were found before teardown' >&2
  exit 1
fi
```

次に、運用者が Git の desired state から `clusters/home/resources/neon-demo.yaml` を取り除き、その変更を commit して push する。

```bash
git rm clusters/home/resources/neon-demo.yaml
git commit -m "chore: remove neon demo cluster"
git push

flux reconcile kustomization cluster-resources \
  --namespace=flux-system \
  --with-source \
  --timeout=10m

kubectl -n flux-system --request-timeout=5m \
  wait kustomization/cluster-resources \
  --for=condition=Ready --timeout=5m
```

commit と push は、Cluster を削除する権限を持つ運用者が内容を確認して実行する。

期限付き reconcile と Ready 確認の両方が成功してから、削除確認へ進む。

Cluster の削除と PVC の削除を、それぞれ最大 10 分待つ。

```bash
kubectl -n database --request-timeout=10m \
  wait --for=delete cluster/neon-demo --timeout=10m

pvc_deadline=$((SECONDS + 600))
remaining_pvcs=("${neon_pvcs[@]}")

while (( SECONDS < pvc_deadline && ${#remaining_pvcs[@]} > 0 )); do
  next_remaining_pvcs=()

  for pvc in "${remaining_pvcs[@]}"; do
    if pvc_state="$(
      kubectl -n database --request-timeout=15s \
        get "$pvc" --ignore-not-found=true -o name
    )"; then
      if [[ -n "$pvc_state" ]]; then
        next_remaining_pvcs+=("$pvc")
      fi
    else
      next_remaining_pvcs+=("$pvc")
    fi
  done

  remaining_pvcs=("${next_remaining_pvcs[@]}")

  if (( SECONDS >= pvc_deadline )); then
    break
  fi

  sleep 5
done

if (( ${#remaining_pvcs[@]} != 0 )); then
  printf 'Timed out waiting for PVC removal: %s\n' \
    "${remaining_pvcs[*]}" >&2
  exit 1
fi
```

最後に、pCloud 上の `neon-demo` bucket が残っていることを、認証情報を表示せずに確認する。

```bash
gateway_pod="$(get_gateway_pod)"

kubectl -n pcloud-s3 --request-timeout=30s \
  exec "$gateway_pod" -c rclone -- \
  rclone lsd pcloud:buckets |
  awk '$NF == "neon-demo" {found=1} END {exit !found}'
```

最後のコマンドが成功すれば、`neon-demo` remote bucket は残っている。

`Delete` は検証用 Cluster の Kubernetes リソースを削除するポリシーであり、external storage まで消去する `WipeOut` ではない。
