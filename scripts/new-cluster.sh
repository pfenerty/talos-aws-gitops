#!/usr/bin/env bash
# Copy clusters/template to clusters/<name>, where <name> is the cluster's
# project_name in talos-aws-terraform. Commit and push the result before that
# cluster's first `terraform apply`.
#
# The copy rewrites clusters/template/ to clusters/<name>/ in the Flux
# Kustomizations, whose paths are relative to the repository root and so name
# the cluster's own directory.
set -euo pipefail

cd "$(dirname "$0")/.."

name="${1:-}"
if ! echo "$name" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
  echo "usage: $0 <project_name>   (lowercase letters, digits and dashes)" >&2
  exit 2
fi
if [ -e "clusters/$name" ]; then
  echo "clusters/$name already exists" >&2
  exit 1
fi

cp -R clusters/template "clusters/$name"
find "clusters/$name" -name '*.yaml' -exec sed -i.bak "s#clusters/template/#clusters/$name/#g" {} +
find "clusters/$name" -name '*.bak' -delete

echo "created clusters/$name; run ./scripts/validate.sh, then commit and push before terraform apply"
