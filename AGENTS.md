# Agent instructions: talos-aws-gitops

The Flux repository for clusters built by
[talos-aws-terraform](https://github.com/pfenerty/talos-aws-terraform). README.md
states the contract: Flux syncs `clusters/<project_name>`, Terraform's bootstrap
writes only `flux-system/` there, and the manifests here read the Secrets and
ConfigMaps Terraform publishes.

## Workspace

This repo is part of `~/code/infra`. See `~/code/infra/CLAUDE.md` for the
other repos and how changes propagate between them.

- **talos-aws-terraform** is upstream. Its README ("Flux bootstrap repository")
  and `modules/bootstrap` define the published objects. Don't rename or
  reshape a consumed key here alone: change Terraform first.
- Everything a cluster runs must be committed under `clusters/<project_name>/`
  *before* that cluster's `terraform apply`.
- Never hand-edit `clusters/*/flux-system/`. Flux bootstrap owns it.

## Quality gates

`flox activate` provides `flux`, `kubectl`, `kustomize`, `kubeconform`, `helm`,
`yq` and `bd`. Before every commit, run the same gate CI runs:

```sh
flox activate -- ./scripts/validate.sh
```

- `postBuild` substitution is a plain string replace across the whole
  Kustomization, so a literal `$` under a substituted path must be written
  `$$`. Adding a substitution variable means adding a stand-in for it to
  `scripts/ci/vars.env`.
- A chart that won't render without a value from `valuesFrom` gets one in
  `scripts/ci/values/<release>.yaml`.
- Shared components under the layer roots (`infrastructure/`,
  `observability/`, `policy/`, `apps/`) carry no cluster-specific values.
  Those go in `clusters/<name>/overlays/` or come from Terraform.
- New clusters come from `scripts/new-cluster.sh`, never from a bare `cp -r`:
  the Flux paths name the cluster's own directory.
- Scripts must run under macOS bash 3.2 and BSD tools as well as on Linux.

## Issue tracking

Beads (`bd`, prefix `gitops`) syncs through Dolt over git (`refs/dolt/data`).
This repo is public, so its beads DB is too: don't use `bd remember`. Durable
knowledge goes in this file. Cross-repo epics live in the infra hub
(`~/code/infra/planning`, prefix `infraplan`). When an issue belongs to one,
note `Parent epic: infraplan-xyz`.

Work on a branch and open a PR. Don't push to `main`.
