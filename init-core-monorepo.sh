#!/usr/bin/env bash
set -euo pipefail

WORKDIR="monorepo-migration"
MONOREPO="monorepo-general"

REPOS=(
  "https://github.com/Netcracker/qubership-core-utils|core-utils"
  "https://github.com/Netcracker/qubership-core-error-handling|core-error-handling"
  "https://github.com/Netcracker/qubership-core-process-orchestrator|core-process-orchestrator"
  "https://github.com/Netcracker/qubership-core-context-propagation|core-context-propagation"
  "https://github.com/Netcracker/qubership-core-microservice-framework-extensions|core-microservice-framework-extensions"
  "https://github.com/Netcracker/qubership-core-mongo-evolution|core-mongo-evolution"
  "https://github.com/Netcracker/qubership-core-junit-k8s-extension|core-junit-k8s-extension"
  "https://github.com/Netcracker/qubership-core-restclient|core-restclient"
  "https://github.com/Netcracker/qubership-core-context-propagation-quarkus|core-context-propagation-quarkus"
  "https://github.com/Netcracker/qubership-core-rest-libraries|core-rest-libraries"
  "https://github.com/Netcracker/qubership-core-blue-green-state-monitor|core-blue-green-state-monitor"
  "https://github.com/Netcracker/qubership-dbaas-client|dbaas-client"
  "https://github.com/Netcracker/qubership-maas-client|maas-client"
  "https://github.com/Netcracker/qubership-maas-client-spring|maas-client-spring"
  "https://github.com/Netcracker/qubership-maas-declarative-client-commons|maas-declarative-client-commons"
  "https://github.com/Netcracker/qubership-core-microservice-dependencies|core-microservice-dependencies"
  "https://github.com/Netcracker/qubership-core-quarkus-extensions|core-quarkus-extensions"
  "https://github.com/Netcracker/qubership-maas-declarative-client-spring|maas-declarative-client-spring"
  "https://github.com/Netcracker/qubership-core-microservice-framework|core-microservice-framework"
  "https://github.com/Netcracker/qubership-core-blue-green-state-monitor-quarkus|core-blue-green-state-monitor-quarkus"
  "https://github.com/Netcracker/qubership-maas-client-quarkus|maas-client-quarkus"
  "https://github.com/Netcracker/qubership-core-springboot-starter|core-springboot-starter"
  "https://github.com/Netcracker/qubership-maas-declarative-client-quarkus|maas-declarative-client-quarkus"
)

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found"; exit 1; }; }

need git
need git-filter-repo

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "==> Step 1: bare clone + keep only main + move to subdir"

for entry in "${REPOS[@]}"; do
  IFS="|" read -r url subdir <<< "${entry}"
  repo="$(basename "${url}" .git)"
  bare="${repo}.git"

  echo "---- ${repo}"

  rm -rf "${bare}"
  git clone --bare --branch main --single-branch "${url}" "${bare}"

  (
    cd "${bare}"

    git filter-repo \
      --refs refs/heads/main \
      --to-subdirectory-filter "${subdir}"
  )
done

echo "==> Step 2: create monorepo"

rm -rf "${MONOREPO}"
git init "${MONOREPO}"
cd "${MONOREPO}"

git commit --allow-empty -m "Initial monorepo commit"

echo "==> Step 3: merge rewritten histories"

for entry in "${REPOS[@]}"; do
  IFS="|" read -r url subdir <<< "${entry}"
  repo="$(basename "${url}" .git)"
  bare="../${repo}.git"

  git remote remove "${subdir}" 2>/dev/null || true
  git remote add "${subdir}" "${bare}"

  git fetch "${subdir}" main

  git merge "${subdir}/main" \
    --allow-unrelated-histories \
    -m "chore(monorepo): merge ${repo} into /${subdir}"
done

echo
echo "DONE. Monorepo is ready."
