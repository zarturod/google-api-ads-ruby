#!/bin/bash
set -euo pipefail
set +x

# Default to dry-run for safety unless DRY_RUN=false is explicitly passed.
DRY_RUN="${DRY_RUN:-true}"
if [[ "${DRY_RUN}" != "true" && "${DRY_RUN}" != "false" ]]; then
  echo "ERROR: DRY_RUN must be 'true' or 'false' (got '${DRY_RUN}')." >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

echo "=== Building and Releasing from: ${REPO_DIR} (DRY_RUN=${DRY_RUN}) ==="

EXIT_GATE_PROJECT="oss-exit-gate-prod"
EXIT_GATE_LOCATION="us"
EXIT_GATE_REPOSITORY="google-api-ads-ruby--rubygems"

build_and_stage_gem() {
  local dir="$1"
  local pkg="$2"
  pushd "${REPO_DIR}/${dir}" >/dev/null
  rm -f *.gem
  gem build "${pkg}.gemspec"
  local gem_file
  gem_file="$(ls "${pkg}"-*.gem | head -n 1)"
  local ver="${gem_file#${pkg}-}"
  ver="${ver%.gem}"

  if gcloud artifacts packages describe "${pkg}" \
      --project="${EXIT_GATE_PROJECT}" \
      --location="${EXIT_GATE_LOCATION}" \
      --repository="${EXIT_GATE_REPOSITORY}" &>/dev/null; then
    gcloud artifacts packages delete "${pkg}" \
      --project="${EXIT_GATE_PROJECT}" \
      --location="${EXIT_GATE_LOCATION}" \
      --repository="${EXIT_GATE_REPOSITORY}" \
      --quiet
  fi

  set +x
  local token
  token="$(gcloud auth print-access-token)"
  curl -fsSL -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"${gem_file}" \
    "https://us-ruby.pkg.dev/${EXIT_GATE_PROJECT}/${EXIT_GATE_REPOSITORY}/api/v1/gems" >&2
  unset token
  popd >/dev/null
  echo "${ver}"
}

SAVON_VER="$(build_and_stage_gem "ads_savon" "google-ads-savon")"
COMMON_VER="$(build_and_stage_gem "ads_common" "google-ads-common")"
DFP_VER="$(build_and_stage_gem "ad_manager_api" "google-dfp-api")"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "=== DRY_RUN is enabled. Skipping manifest upload to Exit Gate. ==="
  exit 0
fi

cat <<EOF > manifest.json
{
  "publish_all": false,
  "publishing_groups": [
    {
      "packages": [
        {
          "name": "google-ads-savon",
          "version": "${SAVON_VER}"
        },
        {
          "name": "google-ads-common",
          "version": "${COMMON_VER}"
        },
        {
          "name": "google-dfp-api",
          "version": "${DFP_VER}"
        }
      ]
    }
  ]
}
EOF

EXIT_GATE_BUCKET="gs://oss-exit-gate-prod-projects-bucket/google-api-ads-ruby/rubygems/manifests"
MANIFEST_NAME="manifest-$(date +%Y%m%d%H%M%S).json"

echo "=== Uploading manifest to ${EXIT_GATE_BUCKET}/${MANIFEST_NAME} ==="
gcloud storage cp manifest.json "${EXIT_GATE_BUCKET}/${MANIFEST_NAME}"
