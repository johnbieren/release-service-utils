#!/usr/bin/env bash
# Clone release-service-catalog, replace konflux-ci release-service-utils image refs with UTILS_IMAGE,
# push to a new GitHub repo.
# Outputs results for Tekton (stdout markers + optional result files).
#
# Required env: GITHUB_TOKEN, UTILS_IMAGE
# Optional: CATALOG_REPO (default konflux-ci/release-service-catalog), CATALOG_REF (development),
#           DEST_REPO_PREFIX (default hacbs-release-tests/catalog-utils-e2e), PIPELINE_UID
set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${UTILS_IMAGE:?UTILS_IMAGE is required}"

CATALOG_REPO="${CATALOG_REPO:-konflux-ci/release-service-catalog}"
CATALOG_REF="${CATALOG_REF:-development}"
DEST_REPO="${DEST_REPO_PREFIX:-hacbs-release-tests/catalog-utils-e2e}-${PIPELINE_UID:-$(date +%s)}"
BRANCH_NAME="${BRANCH_NAME:-patched-utils-e2e}"

CATALOG_CLONE_DIR="$(mktemp -d)"
trap 'rm -rf "${CATALOG_CLONE_DIR}"' EXIT

echo "Cloning ${CATALOG_REPO}@${CATALOG_REF} into ${CATALOG_CLONE_DIR}..."
git clone --depth 1 --branch "${CATALOG_REF}" \
  "https://${GITHUB_TOKEN}@github.com/${CATALOG_REPO}.git" "${CATALOG_CLONE_DIR}"
cd "${CATALOG_CLONE_DIR}"
# Shallow clone + push to an empty repo often yields "did not receive expected object" / index-pack
# on the remote; need a complete object graph for git push to pack correctly.
if [[ -f "$(git rev-parse --git-dir)/shallow" ]]; then
  echo "Fetching full history (git fetch --unshallow) for a reliable push..."
  git fetch --unshallow
fi

CATALOG_BASE_SHA="$(git rev-parse HEAD)"
echo "Recorded CATALOG_BASE_SHA=${CATALOG_BASE_SHA}"

export UTILS_IMAGE
python3 << 'PATCHPY'
import os
import re
from pathlib import Path

# Skip tasks/**/tests/*.yaml (Tekton unit-test fixtures), same rule as
# find_catalog_suite_from_utils_diff._is_under_task_tests_dir.
def _is_under_task_tests_dir(path: Path, tasks_root: Path) -> bool:
    try:
        rel = path.resolve().relative_to(tasks_root.resolve())
    except ValueError:
        return False
    return "tests" in rel.parts


img = os.environ["UTILS_IMAGE"]
# Any registry/repo path ending in /release-service-utils with :tag or @digest (catalog task step images).
utils_image_ref = re.compile(
    r"(?:[\w.-]+/)+release-service-utils(?::[^\s\n\"'#]+|@[^\s\n\"'#]+)"
)
multiline_utils_ref = re.compile(
    r"(image:\s*\n\s*)(?:[\w.-]+/)+release-service-utils(?::[^\s\n\"'#]+|@[^\s\n\"'#]+)",
    re.MULTILINE,
)
root = Path(".").resolve()
tasks_root = root / "tasks"
for path in root.rglob("*.yaml"):
    if tasks_root.is_dir() and _is_under_task_tests_dir(path, tasks_root):
        continue
    text = path.read_text()
    new = utils_image_ref.sub(img, text)
    new = multiline_utils_ref.sub(r"\1" + img, new)
    if new != text:
        path.write_text(new)
PATCHPY

if git diff --quiet; then
  echo "ERROR: No YAML changes after patching release-service-utils image refs." >&2
  echo "       Check that catalog tasks still reference quay.io/konflux-ci/release-service-utils@" >&2
  exit 1
fi

echo "${CATALOG_BASE_SHA}" > .utils-e2e-catalog-base-sha

# GitHub rejects PAT pushes that add/update workflow YAML unless the token has workflow scope.
# This temp fork does not need Actions; drop workflows so a repo-scoped token can push.
if [[ -d .github/workflows ]]; then
  echo "Removing .github/workflows from temp fork (avoids PAT workflow scope on push)."
  rm -rf .github/workflows
fi

git config user.email "utils-e2e@konflux-ci"
git config user.name "konflux-release-team"
git add -A
git commit -m "chore(e2e): use release-service-utils PR image for integration tests"

INTEGRATION_SCRIPTS_DIR="${CATALOG_CLONE_DIR}/integration-tests/scripts"
if [[ ! -f "${INTEGRATION_SCRIPTS_DIR}/create-github-repo.sh" ]]; then
  echo "ERROR: create-github-repo.sh not found at ${INTEGRATION_SCRIPTS_DIR}" >&2
  exit 1
fi

echo "Creating GitHub repo ${DEST_REPO}..."
bash "${INTEGRATION_SCRIPTS_DIR}/create-github-repo.sh" "${DEST_REPO}" \
  "Temporary catalog fork for release-service-utils e2e (auto-deleted)" false

git remote add dest "https://${GITHUB_TOKEN}@github.com/${DEST_REPO}.git"
git checkout -b "${BRANCH_NAME}"
git push -u dest "${BRANCH_NAME}"

CATALOG_GIT_URL="https://github.com/${DEST_REPO}"
echo "Pushed patched catalog to ${CATALOG_GIT_URL} branch ${BRANCH_NAME}"

# Optional Tekton result paths: $1 $2 $3 $4 = CATALOG_BASE_SHA, CATALOG_GIT_URL, CATALOG_GIT_REVISION, TEMP_REPO_NAME
if [[ -n "${1:-}" ]]; then echo -n "${CATALOG_BASE_SHA}" > "$1"; fi
if [[ -n "${2:-}" ]]; then echo -n "${CATALOG_GIT_URL}" > "$2"; fi
if [[ -n "${3:-}" ]]; then echo -n "${BRANCH_NAME}" > "$3"; fi
if [[ -n "${4:-}" ]]; then echo -n "${DEST_REPO}" > "$4"; fi
