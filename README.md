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
| `aws-loadbalancer-config` | ConfigMap | AWS load balancer controller |
| `cluster-versions` | ConfigMap | tuppr `TalosUpgrade` / `KubernetesUpgrade`, via `postBuild.substituteFrom` |

A change to any of these names or shapes lands in talos-aws-terraform first,
then here.

## Layout

```
clusters/<project_name>/   one directory per cluster; Flux's sync path
  flux-system/             written by Terraform's bootstrap, not by hand
```

## Development

The Flox environment provides `flux`, `kubectl`, `kustomize`, `kubeconform`
and `bd`:

```sh
flox activate
kustomize build clusters/<project_name> | kubeconform -strict -ignore-missing-schemas
```
