#!/usr/bin/env bash
# Installs or upgrades the third-party charts in charts/third-party/releases.tsv -- all of them, or only
# the releases named as arguments. Runs on the cluster's host (bootstrap, and release.sh after a pull).
#
#   ./install-third-party.sh              # every release
#   ./install-third-party.sh grafana      # just these
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

wanted=" $* "
while IFS=$'\t' read -r release namespace chart repo version; do
    [[ -z "$release" || "$release" == \#* ]] && continue
    [[ $# -gt 0 && "$wanted" != *" $release "* ]] && continue
    echo "--- $release ($chart $version) ---"
    helm upgrade --install "$release" "$chart" --repo "$repo" --version "$version" \
        -n "$namespace" -f "charts/third-party/$release/values.yaml"
done < charts/third-party/releases.tsv
