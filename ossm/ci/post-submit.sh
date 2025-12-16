#!/bin/bash

set -exo pipefail

DIR=$(cd "$(dirname "$0")" ; pwd -P)

GCS_PROJECT=${GCS_PROJECT:-maistra-prow-testing}
ARTIFACTS_GCS_PATH=${ARTIFACTS_GCS_PATH:-gs://maistra-prow-testing/ztunnel}

gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"
gcloud config set project "${GCS_PROJECT}"

# Copy artifacts to GCS
SHA="$(git rev-parse --verify HEAD)"

if [[ "$(uname -m)" == "aarch64" ]]; then
  ARCH_SUFFIX="-arm64"
else
  ARCH_SUFFIX=""
fi

tar czf ./out/rust/release/ztunnel.tar.gz ./out/rust/release/ztunnel
gsutil cp ./out/rust/release/ztunnel.tar.gz "${ARTIFACTS_GCS_PATH}/ztunnel-${SHA}${ARCH_SUFFIX}.tar.gz"
