# talos-aws-gitops

The Flux repository for Kubernetes clusters built by
[talos-aws-terraform](https://github.com/pfenerty/talos-aws-terraform).

Terraform builds the cluster, installs a bootstrap Cilium, waits for the
cluster to go healthy and installs Flux pointed at this repository. Everything
the cluster runs after that is reconciled from here.

## Contract with talos-aws-terraform

Flux syncs `clusters/<project_name>`. Terraform's bootstrap writes only the
`flux-system/` directory inside it. Everything else for a cluster is committed
here *before* `terraform apply`, so the cluster comes up with its add-ons on the
first reconcile.

Terraform publishes these objects, and the manifests here read them by name.
The [talos-aws-terraform README](https://github.com/pfenerty/talos-aws-terraform#flux-bootstrap-repository)
and `modules/bootstrap` are the source of truth for their keys and shapes:

| Object | Kind | Read by |
|--------|------|---------|
| `cilium-config` | Secret | Cilium `HelmRelease` (`valuesFrom`), which adopts the bootstrap install |
| `karpenter-config` | Secret (`flux-system`) | Karpenter `HelmRelease`, `EC2NodeClass`, `NodePool` |
| `karpenter-aws-config` | ConfigMap (`kube-system`) | Karpenter controller `envFrom` |
| `cloud-controller-manager-aws-config` | ConfigMap | AWS cloud controller manager |
| `ebs-csi-driver-aws-config` | ConfigMap | EBS CSI driver |
| `aws-loadbalancer-config` | Secret (`flux-system`) | AWS load balancer controller |
| `cluster-versions` | ConfigMap | tuppr `TalosUpgrade` / `KubernetesUpgrade`, via `postBuild.substituteFrom` |

A change to any of these names or shapes lands in talos-aws-terraform first,
then here.

## Layout

```
clusters/
  template/                 copied to clusters/<project_name> for a new cluster
    kustomization.yaml      the sync root: flux-system/ plus the layer files
    infrastructure.yaml     Flux Kustomizations infra-controllers -> infra-configs
    observability.yaml      Flux Kustomization per optional layer, each
    policy.yaml               depending on infra-configs
    apps.yaml
    overlays/<layer>/       what this cluster takes from each layer, and its
                            cluster-only patches
  <project_name>/
    flux-system/            written by Terraform's bootstrap, not by hand
infrastructure/
  sources/                  shared HTTP HelmRepositories
  controllers/<add-on>/     charts: namespace, OCIRepository, HelmRelease
  configs/<add-on>/         instances of CRDs the controllers register
observability/<add-on>/
policy/<add-on>/
apps/<app>/
```

A cluster is its directory under `clusters/`. Shared manifests live once
under the layer roots and carry no cluster-specific values. A cluster's
`overlays/` choose which components it runs and patch them for that cluster
alone. Anything that comes from Terraform arrives at apply time through
`valuesFrom` or `postBuild.substituteFrom`, never as a copied value.

Each layer is one Flux Kustomization with `wait: true`, so a layer goes Ready
only once everything in it is. Ordering inside a layer comes from
`HelmRelease.spec.dependsOn`. The two infrastructure Kustomizations split at
the CRD boundary, because a custom resource can't apply until its chart has
registered the CRD. To drop an optional layer, delete its file and its line in
the cluster's `kustomization.yaml`. `prune: true` then removes what the layer
installed.

Charts published to an OCI registry come through an `OCIRepository` in the
add-on's own directory, so the chart version sits next to the release that
uses it.

## Adding a cluster

Before that cluster's first `terraform apply`:

```sh
./scripts/new-cluster.sh <project_name>
./scripts/validate.sh
git add clusters/<project_name> && git commit && git push   # via a PR
```

`new-cluster.sh` copies the template and rewrites its Flux paths, which are
relative to the repository root, to the new directory. Terraform then writes
`flux-system/` beside the layer files, and the cluster's first reconcile
brings up everything else.

## Development

The Flox environment provides `flux`, `kubectl`, `kustomize`, `kubeconform`,
`helm`, `yq` and `bd`. `scripts/validate.sh` is the whole quality gate, and CI
runs it on every pull request:

```sh
flox activate -- ./scripts/validate.sh
```

It builds every component and every cluster the way kustomize-controller does,
including `postBuild` substitution against the stand-in values in
`scripts/ci/vars.env`. It validates the output against the Kubernetes and CRD
schemas and renders every `HelmRelease` with `helm template`. It fails a
cluster whose Flux paths point outside its own directory, and it fails a
substitution variable that nothing provides.
