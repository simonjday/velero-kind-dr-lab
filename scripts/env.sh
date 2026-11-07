# shellcheck shell=bash
# Central version pins and names. Sourced by every script.
# Versions verified against upstream release pages on 2026-11-05.

# --- Velero (CNCF Sandbox, github.com/velero-io/velero) ---
export VELERO_VERSION="${VELERO_VERSION:-v1.18.4}"
export VELERO_IMAGE="${VELERO_IMAGE:-velero/velero:${VELERO_VERSION}}"
# Plugin v1.14.x is the documented pairing for Velero v1.18.x
export VELERO_AWS_PLUGIN_IMAGE="${VELERO_AWS_PLUGIN_IMAGE:-velero/velero-plugin-for-aws:v1.14.4}"

# --- kind (v0.33.0 release notes; Velero 1.18 is tested on k8s 1.33-1.35) ---
export KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0}"
export PRIMARY_CLUSTER="${PRIMARY_CLUSTER:-velero-primary}"
export DR_CLUSTER="${DR_CLUSTER:-velero-dr}"
export PRIMARY_CTX="kind-${PRIMARY_CLUSTER}"
export DR_CTX="kind-${DR_CLUSTER}"

# --- Off-cluster object store (SeaweedFS S3 gateway, runs on the 'kind' docker network) ---
export SEAWEEDFS_IMAGE="${SEAWEEDFS_IMAGE:-chrislusf/seaweedfs:4.45}"
export S3_CONTAINER="${S3_CONTAINER:-seaweedfs}"
export S3_VOLUME="${S3_VOLUME:-velero-seaweedfs-data}"
export S3_PORT="${S3_PORT:-8333}"
export S3_BUCKET="${S3_BUCKET:-velero}"
export S3_REGION="${S3_REGION:-us-east-1}"
export S3_ACCESS_KEY="${S3_ACCESS_KEY:-velero}"
export S3_SECRET_KEY="${S3_SECRET_KEY:-velero-lab-secret}"
export AWSCLI_IMAGE="${AWSCLI_IMAGE:-amazon/aws-cli:2.22.0}"
export CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"

# --- Demo workload ---
export DEMO_NS="${DEMO_NS:-dr-demo}"

# --- Paths ---
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LAB_ROOT
export STATE_DIR="${LAB_ROOT}/.state"
export BIN_DIR="${LAB_ROOT}/bin"
export PATH="${BIN_DIR}:${PATH}"

# Force kind onto Docker Desktop even if the shell defaults to Podman
export KIND_EXPERIMENTAL_PROVIDER=docker
