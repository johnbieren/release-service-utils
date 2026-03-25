#!/usr/bin/env bash
#
# run-test.sh - Submit a Tekton PipelineRun for utils-e2e-catalog-pipeline
#
# Overview:
#   Thin wrapper that passes the same parameters an IntegrationTestScenario would use for
#   integration-tests/pipelines/utils-e2e-catalog-pipeline.yaml in release-service-utils. It
#   kubectl-creates a PipelineRun in your cluster (requires kubectl or oc, and jq).
#
# Required environment variables:
#   SNAPSHOT_FILE
#     Path to a Konflux Snapshot JSON file (same shape as the SNAPSHOT pipeline parameter). It
#     must describe the utils build under components[0] (containerImage and source.git url and
#     revision), which the pipeline uses to clone the utils repo and diff against main.
#
#   CATALOG_E2E_RUNNER_IMAGE
#     Image reference for the release-service-catalog image that includes /home/e2e/tests. This
#     becomes the catalogE2eRunnerImage parameter and is what the child catalog e2e PipelineRun
#     uses as its runner image.
#
#   INTEGRATION_TESTS_SUITE_DIR
#     Name of the catalog integration-tests/<name>/ directory to exercise (e.g. e2e). Must match
#     how that suite is wired in catalog RPAs (PIPELINE_TEST_SUITE) for the scenario you are testing.
#
#   PIPELINE_USED
#     Basename of the managed pipeline under catalog pipelines/managed/<name>/ (e.g. fbc-release).
#     Same meaning as catalog e2e env PIPELINE_USED; here it is passed as the managedPipelineName
#     pipeline parameter (then exported as PIPELINE_USED to the child catalog e2e PipelineRun).
#
# Optional / defaults:
#   UTILS_PIPELINE_GIT_URL       Default: jq '.components[0].source.git.url // "https://github.com/..."' then env override.
#   UTILS_PIPELINE_GIT_REVISION  Default: jq '.components[0].source.git.revision // "development"' then env override.
#   NAMESPACE, CATALOG_REPO, … — see pipelines/utils-e2e-catalog-pipeline.yaml
#   (NAMESPACE defaults to rhtap-release-2-tenant). PIPELINE_RUN_WAIT_TIMEOUT for --wait (default: E2E_WAIT_TIMEOUT).
#   RUN_TEST_KEEP_PIPELINERUN=1  With --wait, skip deleting the PipelineRun when finished (debugging).
#
# Options:
#   --dry-run          kubectl create --dry-run=client -o yaml (no PipelineRun created)
#   --wait             After create, block until the PipelineRun finishes (success or failure);
#                      uses PIPELINE_RUN_WAIT_TIMEOUT (default: same as E2E_WAIT_TIMEOUT, 4h).
#                      When the run finishes, deletes the PipelineRun (success or failure) so runs
#                      do not accumulate; set RUN_TEST_KEEP_PIPELINERUN=1 to skip deletion.
#   (default)          Prints how to watch logs / status; does not wait (PipelineRun remains).
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KUBECTL="${KUBECTL:-$(command -v kubectl 2>/dev/null || command -v oc 2>/dev/null || true)}"
[[ -n "${KUBECTL}" ]] || { echo "run-test.sh: need kubectl or oc" >&2; exit 1; }

DRY=false
WAIT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) awk 'NR==1{next} /^set -euo pipefail$/{exit} {print}' "$0"; exit 0 ;;
    --dry-run) DRY=true ;;
    --wait) WAIT=true ;;
    *) echo "run-test.sh: unknown arg: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

: "${SNAPSHOT_FILE:?}" "${CATALOG_E2E_RUNNER_IMAGE:?}" "${INTEGRATION_TESTS_SUITE_DIR:?}" "${PIPELINE_USED:?}"
[[ -f "${SNAPSHOT_FILE}" ]] || { echo "run-test.sh: no such file: ${SNAPSHOT_FILE}" >&2; exit 1; }
jq -e . "${SNAPSHOT_FILE}" >/dev/null || exit 1

# Git resolver for this PipelineRun: snapshot url/revision (jq // defaults); env overrides below.
SNAP_GIT_URL=$(jq -r '.components[0].source.git.url // "https://github.com/konflux-ci/release-service-utils.git"' "${SNAPSHOT_FILE}")
SNAP_GIT_REV=$(jq -r '.components[0].source.git.revision // "development"' "${SNAPSHOT_FILE}")
if [[ "${SNAP_GIT_URL}" == git@github.com:* ]]; then
  SNAP_GIT_URL="https://github.com/${SNAP_GIT_URL#git@github.com:}"
fi
if [[ "${SNAP_GIT_URL}" == https://github.com/* && "${SNAP_GIT_URL}" != *.git ]]; then
  SNAP_GIT_URL="${SNAP_GIT_URL}.git"
fi

NAMESPACE="${NAMESPACE:-rhtap-release-2-tenant}"
CATALOG_REPO="${CATALOG_REPO:-konflux-ci/release-service-catalog}"
CATALOG_REF="${CATALOG_REF:-development}"
DEST_REPO_PREFIX="${DEST_REPO_PREFIX:-hacbs-release-tests/catalog-utils-e2e}"
VAULT_PASSWORD_SECRET_NAME="${VAULT_PASSWORD_SECRET_NAME:-e2e-test-vault-password}"
GITHUB_TOKEN_SECRET_NAME="${GITHUB_TOKEN_SECRET_NAME:-e2e-test-github-token}"
KUBECONFIG_SECRET_NAME="${KUBECONFIG_SECRET_NAME:-e2e-test-service-account-kubeconfig}"
E2E_WAIT_TIMEOUT="${E2E_WAIT_TIMEOUT:-4h}"
PIPELINE_RUN_WAIT_TIMEOUT="${PIPELINE_RUN_WAIT_TIMEOUT:-${E2E_WAIT_TIMEOUT}}"
UTILS_PIPELINE_GIT_URL="${UTILS_PIPELINE_GIT_URL:-${SNAP_GIT_URL}}"
UTILS_PIPELINE_GIT_REVISION="${UTILS_PIPELINE_GIT_REVISION:-${SNAP_GIT_REV}}"
readonly _UTILS_PIPELINE_PATH_IN_REPO='integration-tests/pipelines/utils-e2e-catalog-pipeline.yaml'

echo "run-test.sh: pipelineRef from git url=${UTILS_PIPELINE_GIT_URL} revision=${UTILS_PIPELINE_GIT_REVISION} path=${_UTILS_PIPELINE_PATH_IN_REPO}" >&2

PR_JSON=$(jq -n \
  --arg ns "${NAMESPACE}" --rawfile snap "${SNAPSHOT_FILE}" \
  --arg cei "${CATALOG_E2E_RUNNER_IMAGE}" --arg isd "${INTEGRATION_TESTS_SUITE_DIR}" --arg pu "${PIPELINE_USED}" \
  --arg cr "${CATALOG_REPO}" --arg cref "${CATALOG_REF}" --arg drp "${DEST_REPO_PREFIX}" \
  --arg vp "${VAULT_PASSWORD_SECRET_NAME}" --arg gt "${GITHUB_TOKEN_SECRET_NAME}" --arg kc "${KUBECONFIG_SECRET_NAME}" \
  --arg e2w "${E2E_WAIT_TIMEOUT}" \
  --arg pgu "${UTILS_PIPELINE_GIT_URL}" --arg pgr "${UTILS_PIPELINE_GIT_REVISION}" --arg pgp "${_UTILS_PIPELINE_PATH_IN_REPO}" \
  '{apiVersion:"tekton.dev/v1",kind:"PipelineRun",metadata:{generateName:"utils-e2e-catalog-",namespace:$ns},
    spec:{pipelineRef:{resolver:"git",params:[
      {name:"url",value:$pgu},{name:"revision",value:$pgr},{name:"pathInRepo",value:$pgp}
    ]},params:[
      {name:"SNAPSHOT",value:$snap},{name:"catalogE2eRunnerImage",value:$cei},
      {name:"integrationTestsSuiteDir",value:$isd},{name:"managedPipelineName",value:$pu},
      {name:"catalogRepo",value:$cr},{name:"catalogRef",value:$cref},{name:"destRepoPrefix",value:$drp},
      {name:"vaultPasswordSecretName",value:$vp},{name:"githubTokenSecretName",value:$gt},
      {name:"kubeconfigSecretName",value:$kc},{name:"e2eWaitTimeout",value:$e2w}
    ]}}')

if [[ "${DRY}" == true ]]; then
  echo "${PR_JSON}" | "${KUBECTL}" create --dry-run=client -f - -o yaml
  exit 0
fi

PR_NAME=$(echo "${PR_JSON}" | "${KUBECTL}" create -f - -o jsonpath='{.metadata.name}')
echo "Created PipelineRun ${PR_NAME} in namespace ${NAMESPACE}"

delete_pipelinerun() {
  [[ "${RUN_TEST_KEEP_PIPELINERUN:-}" == 1 ]] && return 0
  local pr=$1
  echo "run-test.sh: deleting pipelinerun ${pr} in ${NAMESPACE}" >&2
  "${KUBECTL}" delete pipelinerun "${pr}" -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
}

print_monitoring_hint() {
  local pr=$1
  cat <<EOF

Monitor this run:
  ${KUBECTL} get pipelinerun "${pr}" -n "${NAMESPACE}" -w
  ${KUBECTL} describe pipelinerun "${pr}" -n "${NAMESPACE}"
  (if tkn is installed)  tkn pipelinerun logs "${pr}" -n "${NAMESPACE}" -f

EOF
}

print_monitoring_hint "${PR_NAME}"

if [[ "${WAIT}" == true ]]; then
  echo "Waiting for completion (timeout ${PIPELINE_RUN_WAIT_TIMEOUT})..."
  if ! "${KUBECTL}" wait --for=jsonpath='{.status.completionTime}' "pipelinerun/${PR_NAME}" -n "${NAMESPACE}" \
    --timeout="${PIPELINE_RUN_WAIT_TIMEOUT}"; then
    echo "run-test.sh: wait failed or timed out" >&2
    delete_pipelinerun "${PR_NAME}"
    exit 1
  fi
  ok=$("${KUBECTL}" get pipelinerun "${PR_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')
  if [[ "${ok}" != "True" ]]; then
    echo "run-test.sh: PipelineRun ${PR_NAME} did not succeed (Succeeded=${ok:-empty})" >&2
    delete_pipelinerun "${PR_NAME}"
    exit 1
  fi
  echo "PipelineRun ${PR_NAME} succeeded."
  delete_pipelinerun "${PR_NAME}"
fi
