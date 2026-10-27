# A node is Ready but runs nothing: the frozen watch cache

First seen 2026-09-02 19:28, diagnosed 2026-09-04. It cost two sessions and
several wrong fixes, because every symptom points at the wrong machine.

## Symptoms

- One node is `Ready`, `kubectl describe` looks fine, SSH works, but the node
  runs **zero** pods and no new pod ever lands on it.
- `kubectl get nodes` is healthy. `kubectl get pods -A` shows a large number of
  `Terminating` and `Pending` pods **cluster-wide**, not just on that node.
- Healthy nodes keep acquiring `node.kubernetes.io/unreachable:NoExecute`. You
  remove the taints; they come back within ~10 minutes.
- The scheduler reports `node(s) had untolerated taint(s)` naming taints that
  were deleted hours ago.
- On the affected node: `/etc/cni/net.d` is empty, `/run/flannel/subnet.env` is
  missing, and kubelet logs `"Waiting for node sync before watching apiserver
  pods"` which never advances to `"Watching apiserver"`.

## What is actually wrong

**Nothing on the node.** The apiserver's watch cache for **one resource** is
frozen, and on the control plane, not the worker.

The mechanism:

1. A control-plane stall desyncs the cacher for a resource (here `nodes`,
   `/registry/minions/`).
2. The cacher retries its re-list **at its own stale revision**.
3. kine has already compacted past that revision, so the re-list fails with
   `required revision has been compacted` — and the cacher does not fall back
   to a fresh revision. It retries the same doomed request every ~5 minutes,
   forever.

kine compacts every 5 minutes and retains roughly 1000 revisions. This cluster
writes ~170 revisions/minute, so there is only about **six minutes** of history:
any cacher desync becomes permanent almost immediately.

The damage spreads because two consumers read from that frozen cache:

- **kubelet's node informer** never syncs, so `nodeHasSynced()` is never true,
  so kubelet never starts its apiserver pod source and receives no pods at all.
  The empty `/etc/cni/net.d` and missing flannel subnet are *downstream* of
  this, not causes.
- **node-lifecycle-controller** reads Ready status from the frozen cache, sees
  stale state, and re-taints healthy nodes `unreachable:NoExecute`, evicting
  their pods. That is the cluster-wide `Terminating` count, and why removed
  taints reappear.

## The one measurement that identifies it

Two read shapes disagree, and only one of them is honest:

```
kubectl get --raw "/api/v1/nodes?resourceVersion=0"   # served from the cache; may be arbitrarily stale
kubectl get --raw "/api/v1/nodes"                     # consistent read; reaches the datastore
```

A frozen cacher answers the first one happily. **A check written with
`resourceVersion=0` reports a perfectly healthy cluster while every informer in
it hangs.** The first investigation of this incident dead-ended on exactly that
mistake, and so did a WatchList probe pinned to `resourceVersion=0`.

What a real informer sends is no `resourceVersion` at all, which demands a
consistent read. That is the request that hangs:

```
/api/v1/nodes?watch=true&sendInitialEvents=true&allowWatchBookmarks=true&resourceVersionMatch=NotOlderThan&resourceVersion=
  -> {"type":"ERROR", ... "Timeout: Too large resource version: <live>, current: <frozen>"}
```

Run the same probe against `pods`; it streams fine. **The wedge is per
resource**, which is why the cluster looks mostly healthy.

Both measurements are automated:

```bash
ops/recover-wedged-apiserver-cache.sh     # read-only, changes nothing
```

It prints cached vs live resourceVersion per resource, runs the reflector-shaped
probe, counts the kine compaction errors, and exits non-zero if a cacher is
wedged.

## Recovery

**There is no API, flag or kubectl verb that resets a single cacher.** Restarting
the k3s server is the only remedy — it reinitialises every cacher at the current
revision. That is a real fix, not a workaround.

It is low risk here and worth stating why: the control plane is single-node on
kine/SQLite, so there is no quorum to lose; the unit is `Restart=always`; and
running pods survive an apiserver bounce. In-flight API calls and watches do not.

```bash
# 1. restore household DNS first if it is down -- see below
ops/recover-wedged-apiserver-cache.sh --install-dns-fallback

# 2. the actual fix
ops/recover-wedged-apiserver-cache.sh --fix

# 3. clear the stale taints once; they should now stay gone
kubectl taint nodes --all node.kubernetes.io/unreachable:NoExecute-

# 4. hand DNS back to the real Deployment
ops/recover-wedged-apiserver-cache.sh --remove-dns-fallback
```

`--fix` re-measures afterwards and fails loudly if the cache did not actually
start tracking. Do not treat a clean `systemctl restart` as success: the restart
proves nothing about the cacher.

If a kubelet has not recovered on its own a few minutes later, restart k3s on
that node too.

## DNS during the outage

AdGuard runs only on `enschede-t1000-1`, and the router points every LAN client
at that host — so this incident takes the household's internet with it, which is
what makes it urgent rather than merely broken.

While the wedge holds, no Deployment can be scheduled onto that node. A **static
pod** is the way out: kubelet reads static pods straight off disk, so they need
neither the node informer nor CNI (hostNetwork pods are explicitly exempt from
the network-readiness gate).

The manifest is committed at `ops/break-glass/adguard-static-pod.yaml`
and is deliberately delivered by nothing: applying it as an ordinary Pod would
double bind `:53` against the real Deployment.

Two deliberate differences from the Deployment's pod spec:

- `dnsPolicy: Default`, not `ClusterFirstWithHostNet` — cluster DNS is
  unreachable from a node in this state.
- **no liveness or readiness probes** — a failing probe would restart-loop the
  household's DNS.

**Remove it once the cluster is fixed.** While the wedge holds, kubelet cannot
register the mirror pod (`"No need to create a mirror pod, since failed to get
node info from the cluster"`), so the scheduler does not know `:53` is taken and
may place the real AdGuard pod on that node, where it crash-loops against the
static one. `--remove-dns-fallback` refuses to run while the cache is still
wedged, because removing it then would just take DNS down.

## Verify DNS by value, not by pod status

A running container proves nothing. Check that it resolves *and* that it is
AdGuard answering, from a host on the LAN — not only over the tailnet:

```bash
dig +short @192.168.0.100 example.com A        # resolves
dig +short @192.168.0.100 doubleclick.net A    # -> 0.0.0.0, so blocklists loaded
```

A Wi-Fi client may fail to reach the wired node while the LAN path is fine
(client isolation on the AP). Probe from another node on the LAN before
concluding DNS is down.

## Prevention, and what is not available

The tight compaction window is what turns a transient desync into a permanent
one. **k3s v1.35.2 exposes no kine compaction or retention knob** —
`--etcd-snapshot-retention` is about snapshots, not revision history, and there
is no passthrough for kine's own settings. So this cannot currently be tuned
away; it is a known sharp edge, and the diagnostic script exists because of it.

Reducing write churn does widen the window in practice. During this incident the
control plane logged **52,864** `failed to find Session for client
<node>` 502s in six hours, from log-follow clients retrying against the dead
node — a large share of the revision churn driving compaction. That subsides once
the affected node is healthy.

## Do not conclude the node is at fault

Ruled out during this incident, all red herrings:

- `iptable_nat` / `iptable_filter` / `nft-expr-counter` modprobe warnings —
  present on the healthy nodes too.
- Empty `/etc/cni/net.d`, missing `/run/flannel/subnet.env` — downstream of the
  wedge; flannel setup runs after the agent's node controller syncs.
- HTTP/2 — tested from the node with `curl --http2`; fine.
- Node credentials — a `client-kubelet` cert reset made things worse and had to
  be restored from backup. The certificates were never the problem.

Compare against a **working node early**. The difference that matters is not on
the broken host.
