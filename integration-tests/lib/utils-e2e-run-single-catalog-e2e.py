#!/usr/bin/env python3
"""Create one PipelineRun for catalog integration tests and wait for completion.

Invokes the pipeline defined in catalog at ``integration-tests/pipelines/e2e-tests-staging-pipeline.yaml``

Used by ``utils-e2e-catalog-pipeline`` task ``run-catalog-e2e``. Expects a single suite pair in env.

Required env:
  KUBECONFIG, CATALOG_GIT_URL, CATALOG_GIT_REVISION, CATALOG_E2E_RUNNER_IMAGE,
  PIPELINE_TEST_SUITE, PIPELINE_USED,
  VAULT_PASSWORD_SECRET_NAME, GITHUB_TOKEN_SECRET_NAME, KUBECONFIG_SECRET_NAME

Optional:
  E2E_WAIT_TIMEOUT (default 4h)
  PARENT_PIPELINE_RUN, E2E_GENERATE_NAME_PREFIX
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

CATALOG_E2E_NAMESPACE = "dev-release-team-tenant"


def _require_env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        print(f"ERROR: {name} is required", file=sys.stderr)
        sys.exit(1)
    return v


def _build_snapshot(*, runner: str, url: str, rev: str) -> dict[str, object]:
    return {
        "application": "utils-orchestrated-e2e",
        "artifacts": {},
        "components": [
            {
                "containerImage": runner,
                "name": "catalog-e2e",
                "source": {"git": {"revision": rev, "url": url}},
            }
        ],
    }


def _build_catalog_e2e_pipelinerun(
    *,
    ns: str,
    prefix: str,
    parent: str,
    suite: str,
    snap: dict[str, object],
    pipeline_used: str,
    vault_password_secret_name: str,
    github_token_secret_name: str,
    kubeconfig_secret_name: str,
) -> dict[str, object]:
    return {
        "apiVersion": "tekton.dev/v1",
        "kind": "PipelineRun",
        "metadata": {
            "generateName": prefix,
            "namespace": ns,
            "labels": {
                "app.kubernetes.io/managed-by": "utils-e2e-catalog-pipeline",
                "utils-e2e/parent": parent,
                "utils-e2e/suite": suite,
            },
        },
        "spec": {
            "pipelineRef": {
                "resolver": "git",
                "params": [
                    {"name": "url", "value": "https://github.com/konflux-ci/release-service-catalog.git"},
                    {"name": "revision", "value": "development"},
                    {
                        "name": "pathInRepo",
                        "value": "integration-tests/pipelines/e2e-tests-staging-pipeline.yaml",
                    },
                ],
            },
            "params": [
                {"name": "SNAPSHOT", "value": json.dumps(snap)},
                {"name": "PIPELINE_TEST_SUITE", "value": suite},
                {"name": "PIPELINE_USED", "value": pipeline_used},
                {"name": "VAULT_PASSWORD_SECRET_NAME", "value": vault_password_secret_name},
                {"name": "GITHUB_TOKEN_SECRET_NAME", "value": github_token_secret_name},
                {"name": "KUBECONFIG_SECRET_NAME", "value": kubeconfig_secret_name},
            ],
        },
    }


def main() -> None:
    _require_env("KUBECONFIG")
    ns = CATALOG_E2E_NAMESPACE
    url = _require_env("CATALOG_GIT_URL")
    rev = _require_env("CATALOG_GIT_REVISION")
    runner = _require_env("CATALOG_E2E_RUNNER_IMAGE")
    suite = _require_env("PIPELINE_TEST_SUITE")
    used = _require_env("PIPELINE_USED")

    parent = os.environ.get("PARENT_PIPELINE_RUN", "")
    wait = os.environ.get("E2E_WAIT_TIMEOUT", "4h")
    prefix = os.environ.get("E2E_GENERATE_NAME_PREFIX", "utils-catalog-e2e-")
    vault = os.environ.get("VAULT_PASSWORD_SECRET_NAME", "e2e-test-vault-password")
    gh = os.environ.get("GITHUB_TOKEN_SECRET_NAME", "e2e-test-github-token")
    kc = os.environ.get("KUBECONFIG_SECRET_NAME", "e2e-test-service-account-kubeconfig")

    snap = _build_snapshot(runner=runner, url=url, rev=rev)
    pr = _build_catalog_e2e_pipelinerun(
        ns=ns,
        prefix=prefix,
        parent=parent,
        suite=suite,
        snap=snap,
        pipeline_used=used,
        vault_password_secret_name=vault,
        github_token_secret_name=gh,
        kubeconfig_secret_name=kc,
    )

    path: Path | None = None
    try:
        fd, path_str = tempfile.mkstemp(suffix=".json")
        path = Path(path_str)
        with os.fdopen(fd, "w") as f:
            json.dump(pr, f)

        out = subprocess.check_output(
            ["kubectl", "create", "-f", str(path), "-o", "jsonpath={.metadata.name}"],
            text=True,
        )
        name = out.strip()
        print(f"Created catalog test PipelineRun {name} in {ns} for suite {suite!r}", flush=True)
        subprocess.check_call(
            [
                "kubectl",
                "wait",
                f"pipelinerun/{name}",
                "-n",
                ns,
                "--for=condition=Succeeded",
                f"--timeout={wait}",
            ]
        )
        print(f"PipelineRun {name} succeeded", flush=True)
    finally:
        if path is not None:
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
