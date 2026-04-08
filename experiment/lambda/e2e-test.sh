#!/usr/bin/env bash
# Copyright The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# e2e-test.sh — orchestrates GPU e2e tests on a Lambda Cloud instance.
#
# Must be run from a kubernetes source checkout directory.
# Requires: LAMBDA_API_KEY_FILE, JOB_NAME, BUILD_ID, ARTIFACTS env vars.
# Optional: GPU_TYPE (default: gpu_1x_a10, set empty to accept any available)
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
GPU_TYPE="${GPU_TYPE-gpu_1x_a10}"
GPU_ARGS=()
if [ -n "${GPU_TYPE}" ]; then
  GPU_ARGS=(--gpu "${GPU_TYPE}")
fi
SSH_KEY_NAME=$(echo -n "prow-${JOB_NAME}-${BUILD_ID}" | sha256sum | cut -c1-64)
SSH_DIR=$(mktemp -d /tmp/lambda-ssh.XXXXXX)
SSH_KEY="${SSH_DIR}/key"

# --- Install lambdactl ---
GOPROXY=direct go install github.com/dims/lambdactl@latest

# --- Generate ephemeral SSH key ---
ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -q
SSH_KEY_ID=$(lambdactl --json ssh-keys add "${SSH_KEY_NAME}" "${SSH_KEY}.pub" | jq -r '.id')

cleanup() {
  echo "Cleaning up..."
  [ -n "${INSTANCE_ID:-}" ] && lambdactl stop "${INSTANCE_ID}" --yes 2>/dev/null || true
  [ -n "${SSH_KEY_ID:-}" ] && lambdactl ssh-keys rm "${SSH_KEY_ID}" 2>/dev/null || true
  rm -rf "${SSH_DIR}"
}
trap cleanup EXIT

# --- Launch instance (poll until capacity is available) ---
LAUNCH_OUTPUT=$(lambdactl --json watch \
  "${GPU_ARGS[@]}" \
  --ssh "${SSH_KEY_NAME}" \
  --name "${SSH_KEY_NAME}" \
  --interval 30 \
  --timeout 900 \
  --wait-ssh)
INSTANCE_IP=$(echo "${LAUNCH_OUTPUT}" | jq -r '.ip')
INSTANCE_ID=$(echo "${LAUNCH_OUTPUT}" | jq -r '.id')

remote() { ssh "${SSH_OPTS[@]}" -i "${SSH_KEY}" "ubuntu@${INSTANCE_IP}" "$@"; }
rsync_to() { rsync -e "ssh ${SSH_OPTS[*]} -i ${SSH_KEY}" "$@"; }

# --- Build k8s binaries ---
git fetch --tags --depth 100 origin 2>/dev/null || true
make \
  WHAT="cmd/kubeadm cmd/kubelet cmd/kubectl test/e2e/e2e.test vendor/github.com/onsi/ginkgo/v2/ginkgo"

# --- Transfer binaries to Lambda instance ---
rsync_to _output/local/go/bin/{kubeadm,kubelet,kubectl,e2e.test,ginkgo} "ubuntu@${INSTANCE_IP}:/tmp/"

# --- Set up single-node k8s cluster with GPU support ---
remote bash -s < "${SCRIPT_DIR}/setup-cluster.sh"

# --- Run GPU e2e tests ---
remote bash -s <<TESTEOF
set -eux
export KUBECONFIG=\$HOME/.kube/config
mkdir -p /tmp/gpu-test-artifacts
/tmp/ginkgo \
  -timeout=60m \
  -focus="\[Feature:GPUDevicePlugin\]" \
  -skip="\[Flaky\]" \
  -v \
  /tmp/e2e.test \
  -- \
  --provider=aws \
  --kubeconfig=\$KUBECONFIG \
  --report-dir=/tmp/gpu-test-artifacts \
  --minStartupPods=8
TESTEOF

# --- Collect artifacts ---
mkdir -p "${ARTIFACTS}"
rsync_to "ubuntu@${INSTANCE_IP}:/tmp/gpu-test-artifacts/" "${ARTIFACTS}/" || true
