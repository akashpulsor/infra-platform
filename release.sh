#!/usr/bin/env bash
# One-shot release: build -> push -> bump chart tags (commit + push) -> deploy on the Hetzner box.
#
# Usage (Git Bash, from anywhere):
#   ./release.sh <service>:<tag> [<service>:<tag> ...] [--dry-run] [--no-deploy] [--deploy-only]
#   ./release.sh billing-service:5.0.114-lock-balance creator-ui:0.1.381-lock-balance
#
# --deploy-only skips build/push/commit -- for retrying the box step once the images and the
# chart commit are already out.
#
# Backend services reuse build-and-push.sh (its SERVICES entry is updated to the new tag first, so
# that array stays the release's source of truth). creator-ui is built from the UI repo. Both chart
# values files plus build-and-push.sh are committed in ONE commit and pushed, then the box pulls
# and runs helm upgrade for only the releases that changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_REPO="${UI_REPO:-$(cd "${SCRIPT_DIR}/../../v4/dalai-llama" 2>/dev/null && pwd || echo "")}"
REGISTRY="akashtripathi"
SERVER="${SERVER:-root@49.12.46.177}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/dalai_deploy}"
REMOTE_REPO="/root/infra-platform"
NAMESPACE="apps"

DRY_RUN=false
DEPLOY=true
BUILD=true
BACKEND=()
UI_TAG=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --no-deploy) DEPLOY=false ;;
        --deploy-only) BUILD=false ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        creator-ui:*) UI_TAG="${arg#*:}" ;;
        *:*) BACKEND+=("$arg") ;;
        *) echo "ERROR: expected <service>:<tag>, got '$arg'"; exit 1 ;;
    esac
done
# --deploy-only with nothing named still deploys: it pulls the box and applies any chart change
# (e.g. a gateway routing edit) without building an image.
(( ${#BACKEND[@]} > 0 )) || [[ -n "$UI_TAG" ]] || ! $BUILD || { echo "ERROR: nothing to release"; exit 1; }

run() {
    if $DRY_RUN; then echo "  [dry-run] $*"; else echo "  \$ $*"; "$@"; fi
}

cd "$SCRIPT_DIR"
summary="$(printf '%s, ' "${BACKEND[@]}" ${UI_TAG:+"creator-ui ${UI_TAG}"} | sed 's/:/ /g; s/, $//')"

if $BUILD; then

# Fail before touching anything: a stopped Docker Desktop otherwise fails every build in turn.
if ! $DRY_RUN && ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker engine is not reachable -- start Docker Desktop, wait for 'Engine running', retry."
    exit 1
fi

run git pull --ff-only

# --- 1+2. Backend: pin tags in build-and-push.sh, then build + push + patch values.yaml ---------
if (( ${#BACKEND[@]} > 0 )); then
    names=()
    for entry in "${BACKEND[@]}"; do
        svc="${entry%%:*}"
        grep -q "\"${svc}:" build-and-push.sh || { echo "ERROR: ${svc} is not in build-and-push.sh SERVICES"; exit 1; }
        run sed -i "s|\"${svc}:[^\"]*\"|\"${entry}\"|" build-and-push.sh
        names+=("$svc")
    done
    flags=(--skip-login --skip-git)
    $DRY_RUN && flags+=(--dry-run)
    ./build-and-push.sh "${flags[@]}" "${names[@]}"
fi

# --- 1+2. creator-ui: build + push + patch its chart ------------------------------------------
if [[ -n "$UI_TAG" ]]; then
    [[ -d "$UI_REPO" ]] || { echo "ERROR: UI repo not found; set UI_REPO=/path/to/dalai-llama"; exit 1; }
    image="${REGISTRY}/creator-ui:${UI_TAG}"
    run docker build -f "${UI_REPO}/apps/creator-ui/Dockerfile" -t "$image" "$UI_REPO"
    run docker push "$image"
    run sed -i "s|^  tag: .*|  tag: ${UI_TAG}|" charts/creator-ui/values.yaml
fi

# --- 3. One commit for the whole release --------------------------------------------------------
if $DRY_RUN; then
    echo "  [dry-run] git commit -m \"${summary}\" && git push"
elif git diff --quiet -- release.sh build-and-push.sh charts/backend-service/values.yaml charts/creator-ui/values.yaml; then
    echo "  No chart changes to commit (tags already matched)."
else
    git add release.sh build-and-push.sh charts/backend-service/values.yaml charts/creator-ui/values.yaml
    git commit -m "$summary"
    git push
fi

fi

# --- 4. Deploy on the box: pull, show every tag the pull moves, upgrade only what changed -------
$DEPLOY || { echo "Skipping deploy (--no-deploy)."; exit 0; }

remote="set -euo pipefail
cd ${REMOTE_REPO}
# Someone editing the box's checkout by hand would make the pull silently diverge from git, so
# stop and show it rather than stash or discard work that isn't ours to throw away.
if ! git diff --quiet; then
    echo 'ERROR: ${REMOTE_REPO} has local edits on the box -- review them, then stash or commit:'
    git status --short
    git diff --stat
    exit 1
fi
before=\$(git rev-parse HEAD)
git pull --ff-only
echo '--- tags moved by this pull (all of these will roll) ---'
git diff \"\$before\"..HEAD -- charts/*/values.yaml | grep -E '^[+-] +tag:' || echo '  (none)'
# Platform charts (routing, certificates and the ops gate in gateway; our observability config in
# observability-config) ship with the release that changed them.
for chart in istio-ingressgateway gateway observability-config; do
    if ! git diff --quiet \"\$before\"..HEAD -- charts/\$chart; then
        echo \"--- \$chart chart changed: upgrading its release ---\"
        helm upgrade --install \$chart charts/\$chart -n istio-system -f charts/\$chart/values.yaml
    fi
done
# Third-party releases (charts/third-party/<release>/) whose values or pinned version changed.
changed=\$(git diff --name-only \"\$before\"..HEAD -- charts/third-party | awk -F/ '{print \$3}' | grep -v releases.tsv | sort -u | tr '\\n' ' ' || true)
if ! git diff --quiet \"\$before\"..HEAD -- charts/third-party/releases.tsv; then ./install-third-party.sh;
elif [ -n \"\$changed\" ]; then ./install-third-party.sh \$changed; fi"
if (( ${#BACKEND[@]} > 0 )); then
    remote+="
helm upgrade backend charts/backend-service -n ${NAMESPACE} -f charts/backend-service/values.yaml -f charts/backend-service/values-secret.yaml"
    for entry in "${BACKEND[@]}"; do
        remote+="
kubectl -n ${NAMESPACE} rollout status deploy/${entry%%:*} --timeout=600s"
    done
fi
if [[ -n "$UI_TAG" ]]; then
    remote+="
helm upgrade creator-ui charts/creator-ui -n ${NAMESPACE} -f charts/creator-ui/values.yaml
kubectl -n ${NAMESPACE} rollout status deploy/creator-ui --timeout=300s"
fi
remote+="
kubectl -n ${NAMESPACE} get pods -o wide | grep -E '$(printf '%s|' "${BACKEND[@]%%:*}" ${UI_TAG:+creator-ui} | sed 's/|$//')'"

if $DRY_RUN; then
    echo "  [dry-run] ssh -i ${SSH_KEY} ${SERVER} <<'REMOTE'"; echo "$remote"; echo "REMOTE"
else
    ssh -i "$SSH_KEY" "$SERVER" "bash -s" <<< "$remote"
fi
echo "Release done: ${summary}"
