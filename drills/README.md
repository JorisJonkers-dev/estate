# Drills

Each script here runs one live drill: a question about the cluster that only
the cluster can answer, asked in a throwaway namespace and cleaned up after.
Each settles a claim deploy-kit's decisions rest on, and posts its result on
the issue that asks it.

| script | issue | what it measures | where to run it |
|---|---|---|---|
| [`pool-address-failover.sh`](pool-address-failover.sh) | JorisJonkers-dev/deploy-kit#372 | how long DNS goes unanswered when the node announcing one pool address fails, for a pod failure and a node failure | a machine on the Enschede LAN; the drill takes the announcing node off the network for 90 s |
| [`flagger-spread-promotion.sh`](flagger-spread-promotion.sh) | JorisJonkers-dev/deploy-kit#371 | whether Flagger keeps `matchLabelKeys` on its primary, and promotes a Process with as many replicas as nodes | anywhere kubectl reaches the cluster |
| [`rabbitmq-rotation.sh`](rabbitmq-rotation.sh) | JorisJonkers-dev/deploy-kit#369 | whether VSO moves a connected RabbitMQ consumer onto a new credential before Vault deletes the old user | anywhere kubectl reaches the cluster; Vault signs you in |

## How a drill runs

```bash
./drills/<drill>.sh --check   # the preflight alone: reads only, changes nothing
./drills/<drill>.sh           # the drill
```

- **It makes its own changes.** Each, from creating the namespace to removing
  it, is a block of commands the drill shows, saves in the run's record and
  runs, stopping if they fail. Between changes it checks the cluster, Vault,
  RabbitMQ and the network itself, and moves on once the change has taken
  effect. A run that goes to plan asks for one Enter at the start and, for
  the pool-address drill, one judgement at the end; without a terminal it
  asks nothing and leaves the judgement to the issue.
- **`DRILL_HAND=1` hands every change to you instead**, copied to the
  clipboard to run in a second terminal; the first wait after it waits at your
  pace, with no time limit, and `c` copies the change again.
- **While it waits**, `s` gives up on the wait and `q` stops the drill. A wait
  that times out asks whether to keep waiting, carry on, or stop.
- **Stopping early removes what it created.** A run that finds an earlier
  run's namespace removes it first. An unexpected failure names the line and
  command that failed.
- **The record** is `~/.local/state/estate-drills/<issue>-<time>/`
  (`DRILL_STATE` moves it): every line the drill printed, every change and its
  output, the logs it took, and `result.md`, which it posts on the issue with
  `gh issue comment` and waits for (`DRILL_POST=no` writes it only).

`DRILL_CONTEXT` sets the kubectl context, and `DRILL_NODES="a b"` the two nodes
a drill runs on; each script's header names its own settings. The drills need
bash 5, `kubectl`, `jq` and `python3`; the RabbitMQ drill also needs `vault`,
and the pool-address drill `dig`.

The scripts share [`lib/drill.sh`](lib/drill.sh), which sits on the bootstrap
scripts' [`wizard.sh`](../bootstrap/lib/wizard.sh) and
[`estate.sh`](../bootstrap/lib/estate.sh): the same output, the same Vault
sign-in. Unlike a bootstrap wizard, a drill never clears the screen, so what
it saw stays on screen. [`lib/probe.py`](lib/probe.py) is the pool-address
drill's DNS prober, and [`lib/rabbitmq-consumer.py`](lib/rabbitmq-consumer.py)
the consumer the RabbitMQ drill deploys.
