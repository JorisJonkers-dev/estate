# Packages proxy tests

`run.sh` runs the proxy, the gate and the cargo-config sidecar on this machine, from `../config/`,
and checks them with each script in `cases/`. It uses test keys made up for the run.

```bash
PROXY_BIN=<packages-proxy build> TRAEFIK_BIN=$(command -v traefik) BUSYBOX_BIN=$(command -v busybox) \
  platform/packages/tests/run.sh            # every case
platform/packages/tests/run.sh cases/ready.sh   # one case
```

Build the proxy binary from JorisJonkers-dev/packages-proxy (upstream at `UPSTREAM_COMMIT` with
`proxy/patches/` applied), so the cases see the patched behaviour the cluster runs. The cases
reach the public registries.

A change to `../config/` comes with a case: write it first, see it fail, then change the config.
