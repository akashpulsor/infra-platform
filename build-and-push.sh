#!/usr/bin/env bash
# Build + push all backend service Docker images to Docker Hub.
#
# Sequential on purpose -- three parallel Maven-in-Docker builds crashed Docker Desktop's
# WSL backend on this box before. Fail-fast per service; on any failure, subsequent services
# are skipped so you don't waste a 5-minute rebuild queue behind a broken one.
#
# This script lives in infra-platform but builds images from the sibling dallai-llama-backend
# repo. It auto-resolves the backend path as ../dallai-llama-backend relative to itself, or
# override with BACKEND_REPO=/some/path.
#
# Usage:
#   ./build-and-push.sh                          # build + push every service listed below
#   ./build-and-push.sh --dry-run                # print the commands, don't run them
#   ./build-and-push.sh --skip-login             # you already did `docker login` this session
#   ./build-and-push.sh --skip-git               # don't commit/push the chart tag updates
#   ./build-and-push.sh svc1 svc2 ...            # build+push only these services
#   BACKEND_REPO=/custom/path ./build-and-push.sh   # override backend location
#
# Edit the SERVICES array below to change tags. Repository is fixed at akashtripathi/<name>.
# On a successful push, this script also patches that service's `tag:` in
# charts/backend-service/values.yaml to match -- the SERVICES array here is the single source of
# truth for a release. Once every build+push finishes, it commits just that values.yaml change
# and pushes infra-platform, so a release ends with the chart already reflecting what's live on
# Docker Hub instead of a manual follow-up edit.

set -euo pipefail

# Resolve script directory, then default BACKEND_REPO to its sibling dallai-llama-backend.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_REPO="${BACKEND_REPO:-$(cd "${SCRIPT_DIR}/../dallai-llama-backend" 2>/dev/null && pwd || echo "")}"

if [[ -z "$BACKEND_REPO" || ! -d "$BACKEND_REPO" ]]; then
    echo "ERROR: cannot find backend repo. Expected sibling ../dallai-llama-backend/ next to $(dirname "$SCRIPT_DIR")"
    echo "       Override with: BACKEND_REPO=/path/to/dallai-llama-backend $0"
    exit 1
fi

REGISTRY="akashtripathi"
VALUES_FILE="${SCRIPT_DIR}/charts/backend-service/values.yaml"

# Every entry: "<service-dir>:<tag>"
# The Dockerfile is expected at ${BACKEND_REPO}/<service-dir>/Dockerfile.
SERVICES=(
    "tenant-service:5.0.89-creator-margin"
    "product-service:5.0.91"
    "billing-service:5.0.96-project-spend-cap"
    "llm-gateway:0.1.52-format-logs"
    "video-generation-service:0.2.8-prepare-batch-logs"
    "post-production-service:0.1.4-minio-fix"
    "pre-production-service:0.1.59-prepare-logs"
    "critic-service:0.1.2-gemini-embedding-001"
    "creative-planning-service:0.1.17-margin-recompute"
    "trend-intelligence-service:0.1.0"
    "chat-service:0.1.4-gemini-embedding-001"
)

DRY_RUN=false
SKIP_LOGIN=false
SKIP_GIT=false
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --skip-login) SKIP_LOGIN=true ;;
        --skip-git) SKIP_GIT=true ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

# Filter to command-line-named services if any were given.
if (( ${#POSITIONAL[@]} > 0 )); then
    FILTERED=()
    for entry in "${SERVICES[@]}"; do
        svc="${entry%%:*}"
        for wanted in "${POSITIONAL[@]}"; do
            if [[ "$svc" == "$wanted" ]]; then
                FILTERED+=("$entry")
            fi
        done
    done
    if (( ${#FILTERED[@]} == 0 )); then
        echo "ERROR: none of the requested services match the SERVICES list:"
        printf '  - %s\n' "${POSITIONAL[@]}"
        exit 1
    fi
    SERVICES=("${FILTERED[@]}")
fi

run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        echo "  \$ $*"
        "$@"
    fi
}

echo "=================================================================="
echo " Build + push ${#SERVICES[@]} service(s) to ${REGISTRY}/*"
echo " Backend repo: ${BACKEND_REPO}"
echo "=================================================================="
for entry in "${SERVICES[@]}"; do
    printf "  %-30s %s\n" "${entry%%:*}" "${entry##*:}"
done
echo

# Docker builds need the backend repo as the build context.
cd "$BACKEND_REPO"

# --- Docker Hub login -------------------------------------------------------
if ! $SKIP_LOGIN; then
    echo "--- docker login ---"
    if $DRY_RUN; then
        echo "  [dry-run] docker login"
    else
        # Interactive login prompts for username + password/token. If credentials are already
        # cached in Docker Desktop's keychain, this is a no-op and returns immediately.
        if ! docker login; then
            echo "ERROR: docker login failed. Aborting before any build."
            exit 1
        fi
    fi
    echo
fi

# --- Build + push each service (sequential) ---------------------------------
FAILED=()
TAGGED=()
STARTED_AT=$(date +%s)

for entry in "${SERVICES[@]}"; do
    svc="${entry%%:*}"
    tag="${entry##*:}"
    image="${REGISTRY}/${svc}:${tag}"
    svc_started=$(date +%s)

    echo "=================================================================="
    echo " ${svc} -> ${image}"
    echo "=================================================================="

    if [[ ! -f "${svc}/Dockerfile" ]]; then
        echo "  SKIP: ${svc}/Dockerfile not found in ${BACKEND_REPO}"
        FAILED+=("$svc (no Dockerfile)")
        continue
    fi

    if ! run docker build -f "${svc}/Dockerfile" -t "$image" .; then
        echo "  FAIL: build failed for ${svc}"
        FAILED+=("$svc (build)")
        continue
    fi

    if ! run docker push "$image"; then
        echo "  FAIL: push failed for ${svc}"
        FAILED+=("$svc (push)")
        continue
    fi

    # Keep charts/backend-service/values.yaml's tag in lockstep with what was just pushed --
    # repository/tag are an adjacent, unique line pair per service, so a two-line sed is
    # unambiguous without needing a YAML-aware tool.
    tag_patch="/repository: ${svc}\$/{n;s/tag: \".*\"/tag: \"${tag}\"/}"
    if $DRY_RUN; then
        echo "  [dry-run] sed -i \"${tag_patch}\" ${VALUES_FILE}"
    else
        if [[ -f "$VALUES_FILE" ]] && grep -q "repository: ${svc}$" "$VALUES_FILE"; then
            sed -i "$tag_patch" "$VALUES_FILE"
            TAGGED+=("$svc -> $tag")
        else
            echo "  WARN: no 'repository: ${svc}' entry found in ${VALUES_FILE}; chart tag left unchanged"
        fi
    fi

    svc_elapsed=$(( $(date +%s) - svc_started ))
    printf "  OK: %s (%ds)\n" "$svc" "$svc_elapsed"
done

# --- Commit + push the chart tag updates ------------------------------------
GIT_PUSHED=false
if ! $SKIP_GIT && (( ${#TAGGED[@]} > 0 )); then
    echo
    echo "--- chart commit + push ---"
    commit_msg="Bump backend image tags

$(printf '%s\n' "${TAGGED[@]}" | sed 's/^/- /')"

    if $DRY_RUN; then
        echo "  [dry-run] git -C ${SCRIPT_DIR} add charts/backend-service/values.yaml"
        echo "  [dry-run] git -C ${SCRIPT_DIR} commit -m \"Bump backend image tags ...\""
        echo "  [dry-run] git -C ${SCRIPT_DIR} push"
    elif git -C "$SCRIPT_DIR" diff --quiet -- charts/backend-service/values.yaml; then
        echo "  No chart changes to commit (tags already matched)."
    elif git -C "$SCRIPT_DIR" add charts/backend-service/values.yaml \
      && git -C "$SCRIPT_DIR" commit -m "$commit_msg" \
      && git -C "$SCRIPT_DIR" push; then
        echo "  OK: committed and pushed chart tag updates"
        GIT_PUSHED=true
    else
        echo "  FAIL: git commit/push failed for chart tag updates"
        FAILED+=("git commit/push")
    fi
fi

# --- Summary ----------------------------------------------------------------
elapsed=$(( $(date +%s) - STARTED_AT ))
echo
if (( ${#TAGGED[@]} > 0 )); then
    echo "--- chart tags updated in ${VALUES_FILE} ---"
    printf '  - %s\n' "${TAGGED[@]}"
    if ! $GIT_PUSHED; then
        echo "  Review with: git diff charts/backend-service/values.yaml"
    fi
    echo
fi
echo "=================================================================="
if (( ${#FAILED[@]} == 0 )); then
    echo " ALL ${#SERVICES[@]} SERVICES BUILT + PUSHED in ${elapsed}s"
    echo "=================================================================="
    exit 0
else
    echo " COMPLETED with ${#FAILED[@]} failure(s) in ${elapsed}s"
    echo "=================================================================="
    printf ' - %s\n' "${FAILED[@]}"
    exit 1
fi
