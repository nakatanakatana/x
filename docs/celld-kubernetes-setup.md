# celld Kubernetes 運用手順

この手順は、home cluster の Ceph RGW と vcluster の celld Fleet を運用するプラットフォーム管理者向けです。
celld の Worker は、承認済みの運用環境からのみ追加します。
`celld deploy` に使う credentials は Git や CI へ保存しないでください。

## kubectl context の設定

host cluster と vcluster を current context に依存して操作すると、同名 resource を誤った cluster で変更する危険があります。
以降の手順を実行する同じ shell session で、対象を確認しながらそれぞれの context 名を入力します。
空の値または同じ context は受け付けません。

```bash
read -r -p 'host Kubernetes context: ' HOST_CONTEXT
read -r -p 'celld vcluster Kubernetes context: ' VCLUSTER_CONTEXT
test -n "$HOST_CONTEXT"
test -n "$VCLUSTER_CONTEXT"
test "$HOST_CONTEXT" != "$VCLUSTER_CONTEXT"
readonly HOST_CONTEXT VCLUSTER_CONTEXT
kubectl --context "$HOST_CONTEXT" cluster-info
kubectl --context "$VCLUSTER_CONTEXT" cluster-info
```

表示された cluster が想定と異なる場合や、両方の context を明確に識別できない場合は、以降の操作を実行しないでください。

## ストレージと Fleet の起動確認

Flux の反映後、まず RGW の `CephObjectStore/celld`、次に `ObjectBucketClaim/celld-storage` が Ready になるまで待ちます。

```bash
kubectl --context "$HOST_CONTEXT" -n rook-ceph wait \
  --for=jsonpath='{.status.phase}'=Ready \
  cephobjectstore/celld --timeout=10m
kubectl --context "$HOST_CONTEXT" -n app wait \
  --for=jsonpath='{.status.phase}'=Bound \
  objectbucketclaim/celld-storage --timeout=10m
```

OBC が生成する `celld-storage` の Secret だけが vcluster の `celld` namespace に同期されます。
ConfigMap は host 側の `app` namespace に残ります。
以下はそれぞれの data の key 名だけを一覧します。Secret の値は復号も表示もしません。

```bash
kubectl --context "$VCLUSTER_CONTEXT" -n celld get secret celld-storage \
  -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}' | sort
kubectl --context "$HOST_CONTEXT" -n app get configmap celld-storage \
  -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}' | sort
```

次に three-Pod StatefulSet の rollout を待ち、3 Pod が Ready であることを確認します。

```bash
kubectl --context "$VCLUSTER_CONTEXT" -n celld rollout \
  status statefulset/celld --timeout=10m
kubectl --context "$VCLUSTER_CONTEXT" -n celld get pods -l app=celld
```

RGW endpoint と peer port `8081` は cluster 内専用です。
外部向けの Service、Ingress、NodePort や常設 tunnel を追加しないでください。
後述する deploy 中だけ、承認済み operator が host context で一時的な port-forward を使います。

## Fleet の Bucket 接続診断

Fleet 内から Bucket 接続を診断します。
credentials は Pod の環境変数から渡されるため、コマンドラインや出力へ値を載せません。

```bash
kubectl --context "$VCLUSTER_CONTEXT" -n celld exec celld-0 -- \
  celld diagnose \
  --bucket s3://celld \
  --endpoint http://rgw.celld.svc.cluster.local:80 \
  --region us-east-1
```

## Worker のデプロイ

runtime が使うのと同じ `celld-storage` credentials を安全に扱える承認済み operator だけが実行します。
非承認者は `celld deploy` を使ってはいけません。
credentials をシェル履歴、Git、CI、Kubernetes manifest、ログへ残さないでください。

operator environment には Worker project source、`celld` CLI、`esbuild`、RGW への到達性が必要です。
同期済み `Secret/celld-storage` の `AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` と同じ値を、承認済みの secret delivery mechanism で operator process の環境変数へ注入してください。
値を手入力したり、この手順へ貼り付けたりしないでください。
Worker project の root を current directory にして、必要な環境変数と tool を確認します。

```bash
: "${AWS_ACCESS_KEY_ID:?supply the celld-storage access key securely}"
: "${AWS_SECRET_ACCESS_KEY:?supply the celld-storage secret key securely}"
command -v celld >/dev/null
command -v esbuild >/dev/null
```

RGW は private のままにし、host context の Rook RGW `service/rook-ceph-rgw-celld`（`rook-ceph` namespace）だけを operator の loopback へ一時転送します。
port-forward を background で起動して到達を確認した後、runtime と同じ bucket と region、および転送先 endpoint を指定して current directory の Worker project を直接 bucket へ deploy します。

```bash
RGW_PORT_FORWARD_LOG="$(mktemp)"
kubectl --context "$HOST_CONTEXT" -n rook-ceph port-forward \
  service/rook-ceph-rgw-celld 18080:80 >"$RGW_PORT_FORWARD_LOG" 2>&1 &
RGW_PORT_FORWARD_PID=$!
cleanup_rgw_port_forward() {
  trap - EXIT HUP INT TERM
  kill "$RGW_PORT_FORWARD_PID" 2>/dev/null || true
  rm -f "$RGW_PORT_FORWARD_LOG"
}
trap cleanup_rgw_port_forward EXIT HUP INT TERM
if ! timeout 30 sh -c \
  'until curl --silent --show-error --output /dev/null --max-time 1 http://127.0.0.1:18080/; do sleep 1; done' || \
  ! kill -0 "$RGW_PORT_FORWARD_PID" 2>/dev/null; then
  tail "$RGW_PORT_FORWARD_LOG" >&2
  exit 1
fi
celld deploy . \
  --bucket s3://celld \
  --endpoint http://127.0.0.1:18080 \
  --region us-east-1
```

deploy が終了したら shell を終了するか `cleanup_rgw_port_forward` を実行し、一時 tunnel を閉じます。

## deploy 後の client verification

MagicDNS URL は deploy 先ではなく、deploy 後の client verification だけに使います。
celld の client endpoint は Tailscale Ingress 経由でのみ公開します。
Ingress の address を取得し、表示された hostname を Tailscale に接続した端末から開いて、Worker が Fleet に到達できることを確認します。

```bash
kubectl --context "$VCLUSTER_CONTEXT" -n celld get ingress celld
kubectl --context "$VCLUSTER_CONTEXT" -n celld get ingress celld \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

たとえば address が `celld.example.ts.net` なら、client verification URL は `https://celld.example.ts.net/` です。

## credential rotation と障害診断

OBC の credential rotation 後は、vcluster 側の `celld-storage` Secret と host 側 `app` namespace の ConfigMap の key 名を上記の方法で確認します。
値を比較または表示してはいけません。
環境変数は既存 Pod に自動反映されないため、一度に一つの Pod だけを再起動し、そのたびに Ready、Fleet 診断、MagicDNS 経由の到達性を確認します。
可用性は operator が一度に一つの Pod だけを削除し、次の削除前に Ready と診断結果を確認することで維持します。
PodDisruptionBudget は Eviction API を使う voluntary disruption に対して 2 Pod の可用性を保護しますが、直接の `kubectl delete pod` は防ぎません。

```bash
kubectl --context "$VCLUSTER_CONTEXT" -n celld delete pod celld-0
kubectl --context "$VCLUSTER_CONTEXT" -n celld wait \
  --for=condition=Ready pod/celld-0 --timeout=10m
kubectl --context "$VCLUSTER_CONTEXT" -n celld exec celld-0 -- \
  celld diagnose \
  --bucket s3://celld \
  --endpoint http://rgw.celld.svc.cluster.local:80 \
  --region us-east-1
```

`celld-1`、`celld-2` についても、前の Pod が Ready になり診断が通ってから同じ操作を繰り返します。
問題が起きた場合は停止中の Pod を増やさず、vcluster context を明示して状態を調べます。

```bash
kubectl --context "$VCLUSTER_CONTEXT" -n celld describe pod celld-0
kubectl --context "$VCLUSTER_CONTEXT" -n celld logs celld-0
```

Secret の取得・表示・ログへの貼り付けは行いません。
