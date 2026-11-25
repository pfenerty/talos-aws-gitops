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

`flox activate` provides `flux`, `kubectl`, `kustomize`, `kubeconform` and
`bd`. Every cluster directory must build and validate:

```sh
kustomize build clusters/<project_name> | kubeconform -strict -ignore-missing-schemas -summary
```

`postBuild` substitution is a plain string replace across the whole
Kustomization, so a literal `$` under a substituted path must be written `$$`.

## Issue tracking

Beads (`bd`, prefix `gitops`) syncs through Dolt over git (`refs/dolt/data`).
This repo is public, so its beads DB is too: don't use `bd remember`. Durable
knowledge goes in this file. Cross-repo epics live in the infra hub
(`~/code/infra/planning`, prefix `infraplan`). When an issue belongs to one,
note `Parent epic: infraplan-xyz`.

Work on a branch and open a PR. Don't push to `main`.
