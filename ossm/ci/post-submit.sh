#!/bin/bash

set -exo pipefail

GCS_PROJECT=${GCS_PROJECT:-maistra-prow-testing}
ARTIFACTS_GCS_PATH=${ARTIFACTS_GCS_PATH:-gs://maistra-prow-testing/ztunnel}

time cargo build --release --features tls-openssl --no-default-features

gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"
gcloud config set project "${GCS_PROJECT}"

# Copy artifacts to GCS
SHA="$(git rev-parse --verify HEAD)"

case $(uname -m) in
  "x86_64") export ARCH=amd64;;
  "aarch64") export ARCH=arm64 ;;
  *) echo "unsupported architecture"; exit 1;;
esac

gsutil cp ./out/rust/release/ztunnel "${ARTIFACTS_GCS_PATH}/ztunnel-${SHA}-${ARCH}"
