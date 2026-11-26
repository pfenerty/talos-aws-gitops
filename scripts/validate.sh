#!/usr/bin/env bash
# Everything CI checks, runnable locally (`flox activate -- ./scripts/validate.sh`).
# Needs kustomize, kubeconform, flux, helm and yq. Talks to no cluster.
#
#   1. Every kustomization outside clusters/ builds.
#   2. Each cluster's Flux Kustomizations point only into that cluster's own
#      directory (a copied template that still says clusters/template is the
#      mistake this catches).
#   3. Each cluster's root builds, and each of its Flux Kustomizations is
#      built the way kustomize-controller builds it: kustomize, then postBuild
#      substitution with the stub values in scripts/ci/vars.env. Substitution
#      is strict, so a variable nothing provides fails here.
#   4. Everything built validates against the Kubernetes and CRD schemas.
#   5. Every HelmRelease renders with `helm template` against the chart and
#      version it names.
#
# Written for bash 3.2 and BSD tools as well as GNU: it runs on macOS as-is.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)

fail=0
note() { printf '\n\033[1m%s\033[0m\n' "$*"; }
bad() { printf '  \033[31m%s\033[0m\n' "$*"; fail=1; }
ok() { printf '  %s\n' "$*"; }
indent() { sed 's/^/    /'; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Kinds kubeconform should not check, comma-separated, for when the CRDs
# catalog's schema lags the chart pinned here. The API server still validates
# them at apply time, against the CRD the chart actually installed.
#   TalosUpgrade, KubernetesUpgrade: the catalog predates prePull and
#   waitForVolumeDetach, which tuppr 0.5.x accepts.
SKIP_KINDS="${SKIP_KINDS:-TalosUpgrade,KubernetesUpgrade}"
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

conform() {
  kubeconform -strict -ignore-missing-schemas \
    ${SKIP_KINDS:+-skip "$SKIP_KINDS"} \
    -schema-location default -schema-location "$CRD_SCHEMAS" \
    -summary "$@" 2>&1
}

# --- 1 ---------------------------------------------------------------------
note "kustomize build (shared components)"
find . -name kustomization.yaml -not -path './.git/*' -not -path './clusters/*' \
  | sed 's#/kustomization.yaml$##' | sort > "$tmp/dirs"
while IFS= read -r dir; do
  if kustomize build "$dir" > "$tmp/out.yaml" 2> "$tmp/err"; then
    ok "$dir"
  else
    bad "$dir"; indent < "$tmp/err"
  fi
done < "$tmp/dirs"

# --- 2-4 -------------------------------------------------------------------
# Per cluster, every rendered manifest is collected in $tmp/<cluster>/all.yaml
# for the helm step, which looks up sources across layers.
for cluster_dir in clusters/*/; do
  cluster=$(basename "$cluster_dir")
  work="$tmp/$cluster"
  mkdir -p "$work"
  : > "$work/all.yaml"
  note "cluster: $cluster"

  # The Flux Kustomizations this cluster declares, outside flux-system/.
  # Files go to yq one by one: concatenated, a file with no leading `---`
  # would merge into the last document of the one before it.
  : > "$work/ks.txt"
  for f in "$cluster_dir"*.yaml; do
    [ "$(basename "$f")" = kustomization.yaml ] && continue
    yq -N 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/*")
           | .metadata.name + " " + .spec.path + " " + ((.spec.postBuild // {}) | length | tostring)' \
      "$f" >> "$work/ks.txt"
  done

  # 3: the root. Before the first apply there is no flux-system/, so build a
  # copy with an empty stand-in.
  if [ -d "$cluster_dir/flux-system" ]; then
    rootdir="$cluster_dir"
  else
    rootdir="$work/root"
    cp -R "$cluster_dir" "$rootdir"
    mkdir -p "$rootdir/flux-system"
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' \
      > "$rootdir/flux-system/kustomization.yaml"
  fi
  if kustomize build "$rootdir" > "$work/root.yaml" 2> "$tmp/err"; then
    if conform "$work/root.yaml" > "$tmp/err"; then ok "root"; else bad "root"; indent < "$tmp/err"; fi
  else
    bad "root"; indent < "$tmp/err"
  fi

  while read -r name path postbuild <&3; do
    [ -n "$name" ] || continue
    # 2
    case "$path" in
      "./clusters/$cluster/"*) ;;
      *) bad "$name: path $path is outside clusters/$cluster/"; continue ;;
    esac
    out="$work/$name.yaml"
    if ! kustomize build "$path" > "$out" 2> "$tmp/err"; then
      bad "$name ($path)"; indent < "$tmp/err"; continue
    fi
    if [ "$postbuild" != "0" ]; then
      if ! (set -a; . scripts/ci/vars.env; set +a; flux envsubst --strict < "$out") > "$out.sub" 2> "$tmp/err"; then
        bad "$name: postBuild substitution"; indent < "$tmp/err"; continue
      fi
      mv "$out.sub" "$out"
    fi
    cat "$out" >> "$work/all.yaml"; printf '\n---\n' >> "$work/all.yaml"
    if [ ! -s "$out" ]; then ok "$name (empty)"; continue; fi
    if conform "$out" > "$tmp/err"; then ok "$name"; else bad "$name"; indent < "$tmp/err"; fi
  done 3< "$work/ks.txt"
done

# --- 5 ---------------------------------------------------------------------
# Values from valuesFrom live in cluster Secrets and are not resolved. A chart
# that will not render without one gets stand-ins from
# scripts/ci/values/<release>.yaml. --api-versions stands in for CRDs other
# releases register, which several charts gate a ServiceMonitor on.
note "helm template"
api_versions="--api-versions monitoring.coreos.com/v1"
rendered=0
for all in "$tmp"/*/all.yaml; do
  [ -f "$all" ] || continue
  cluster=$(basename "$(dirname "$all")")
  hrdir="$tmp/$cluster/hr"
  mkdir -p "$hrdir"
  (cd "$hrdir" && yq -s '"hr-" + $index' 'select(.kind == "HelmRelease")' "$all")
  for hr in "$hrdir"/hr-*.yml; do
    [ -f "$hr" ] || continue
    release=$(yq '.metadata.name' "$hr")
    namespace=$(yq '.spec.targetNamespace // .metadata.namespace' "$hr")
    ref_kind=$(yq '.spec.chartRef.kind // ""' "$hr")
    if [ "$ref_kind" = "OCIRepository" ]; then
      ref_name=$(yq '.spec.chartRef.name' "$hr")
      src=$(yq "select(.kind == \"OCIRepository\" and .metadata.name == \"$ref_name\")" "$all")
      chart=$(echo "$src" | yq '.spec.url')
      version=$(echo "$src" | yq '.spec.ref.tag // .spec.ref.semver')
      set -- "$chart" --version "$version"
    elif [ "$ref_kind" = "" ]; then
      chart_name=$(yq '.spec.chart.spec.chart' "$hr")
      version=$(yq '.spec.chart.spec.version' "$hr")
      ref_name=$(yq '.spec.chart.spec.sourceRef.name' "$hr")
      src=$(yq "select(.kind == \"HelmRepository\" and .metadata.name == \"$ref_name\")" "$all")
      url=$(echo "$src" | yq '.spec.url')
      if [ "$(echo "$src" | yq '.spec.type // "default"')" = "oci" ]; then
        chart="$url/$chart_name"; set -- "$chart" --version "$version"
      else
        chart="$chart_name"; set -- "$chart_name" --repo "$url" --version "$version"
      fi
    else
      bad "$cluster/$release: chartRef kind $ref_kind not handled"; continue
    fi
    if [ -z "$version" ] || [ "$version" = "null" ] || [ "$chart" = "null" ]; then
      bad "$cluster/$release: source $ref_name not found in this cluster's manifests"; continue
    fi
    yq '.spec.values // {}' "$hr" > "$tmp/values.yaml"
    stub="scripts/ci/values/$release.yaml"
    # shellcheck disable=SC2086  # api_versions is deliberately split
    if helm template "$release" "$@" --namespace "$namespace" \
        --values "$tmp/values.yaml" ${api_versions} \
        $( [ -f "$stub" ] && echo "--values $stub" ) > /dev/null 2> "$tmp/err"; then
      ok "$cluster/$release ($chart $version)"
    else
      bad "$cluster/$release ($chart $version)"; indent < "$tmp/err"
    fi
    rendered=$((rendered + 1))
  done
done
[ "$rendered" -gt 0 ] || ok "(no HelmReleases)"

if [ "$fail" -ne 0 ]; then
  printf '\n\033[31mFAILED\033[0m\n'
  exit 1
fi
printf '\n\033[32mOK\033[0m\n'
