# Drills

Each script here runs one live drill: a question about the cluster that only
the cluster can answer, asked in a throwaway namespace and cleaned up after.
Each settles a claim deploy-kit's decisions rest on, and posts its result on
the issue that asks it.

| script | issue | what it measures | where to run it |
|---|---|---|---|
| [`pool-address-failover.sh`](pool-address-failover.sh) | JorisJonkers-dev/deploy-kit#372 | how long DNS goes unanswered when the node announcing one pool address fails, for a pod failure and a node failure | a machine on the Enschede LAN; you take one node off the network |
| [`flagger-spread-promotion.sh`](flagger-spread-promotion.sh) | JorisJonkers-dev/deploy-kit#371 | whether Flagger keeps `matchLabelKeys` on its primary, and promotes a Process with as many replicas as nodes | anywhere kubectl reaches the cluster |
| [`rabbitmq-rotation.sh`](rabbitmq-rotation.sh) | JorisJonkers-dev/deploy-kit#369 | whether VSO moves a connected RabbitMQ consumer onto a new credential before Vault deletes the old user | anywhere kubectl reaches the cluster; Vault signs you in |

## How a drill runs

```bash
./drills/<drill>.sh --check   # the preflight alone: reads only, hands you nothing
./drills/<drill>.sh           # the drill
```

- **It only reads.** Every change, from creating the namespace to removing
  it, is a command the drill shows, copies to the clipboard and saves in the
  run's record, for you to run in a second terminal. It then checks for the
  result itself and moves on: a drill that goes to plan asks for one Enter at
  the start, the actions only you can take (such as pulling a cable), and one
  judgement at the end.
- **While it waits**, `c` copies the command again, `s` gives up on the wait
  and `q` stops the drill. The first wait after a command it hands you waits
  at your pace, with no time limit, and says it is waiting on you. Any other
  wait that times out asks whether to keep waiting, carry on, or stop.
- **Stopping early** prints, and copies, the commands that remove everything
  it asked you to create. A run that finds an earlier run's namespace hands
  you its removal first.
- **The record** is `~/.local/state/estate-drills/<issue>-<time>/`
  (`DRILL_STATE` moves it): every line the drill printed, every command it
  handed you, the logs it took, and `result.md`, the comment it offers to post
  on the issue with `gh issue comment`. It waits until the comment is there.

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
