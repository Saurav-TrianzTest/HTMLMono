#!/bin/bash
# =============================================================================
# build-push.sh — Build and push Docker image for acme-portal-static
# Supports: AWS ECR and Docker Hub
# Usage: ./scripts/build-push.sh
# Run from repository root directory.
# =============================================================================

set -e
set -o pipefail

PROJECT_NAME="acme-portal-static"
DOCKERFILE_PATH="Dockerfile"
BUILD_CONTEXT="."

echo "=============================================="
echo "  acme-portal-static — Docker Build & Push"
echo "=============================================="
echo ""

# ── Tag sanitization ──────────────────────────────────────────────────────────
sanitize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//'
}

IMAGE_NAME=$(sanitize_name "$PROJECT_NAME")
echo "Image name (sanitized): ${IMAGE_NAME}"
echo ""

# ── Prompt for image tag ──────────────────────────────────────────────────────
read -rp "Enter image tag [latest]: " IMAGE_TAG_INPUT
IMAGE_TAG=$(sanitize_name "${IMAGE_TAG_INPUT:-latest}")
if [ -z "$IMAGE_TAG" ]; then
  IMAGE_TAG="latest"
fi
echo "Image tag: ${IMAGE_TAG}"
echo ""

# ── Registry selection ────────────────────────────────────────────────────────
echo "Select container registry:"
echo "  1. AWS ECR"
echo "  2. Docker Hub"
read -rp "Enter choice [1]: " REGISTRY_CHOICE
REGISTRY_CHOICE="${REGISTRY_CHOICE:-1}"

if [ "$REGISTRY_CHOICE" = "1" ]; then
  # ── AWS ECR ──────────────────────────────────────────────────────────────
  echo ""
  echo "--- AWS ECR Configuration ---"
  read -rp "Enter AWS Region [us-east-1]: " AWS_REGION
  AWS_REGION="${AWS_REGION:-us-east-1}"

  read -rp "Enter AWS Account ID: " AWS_ACCOUNT_ID
  if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "Fetching AWS Account ID from STS..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    echo "Account ID: ${AWS_ACCOUNT_ID}"
  fi

  ECR_REPO="${IMAGE_NAME}"
  REGISTRY_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  FULL_IMAGE_NAME="${REGISTRY_URL}/${ECR_REPO}:${IMAGE_TAG}"

  echo ""
  echo "Logging in to Amazon ECR..."
  aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${REGISTRY_URL}"
  echo "ECR login successful."

  # Auto-create ECR repository if it does not exist
  echo "Checking if ECR repository '${ECR_REPO}' exists..."
  aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}"
  echo "ECR repository ready."

elif [ "$REGISTRY_CHOICE" = "2" ]; then
  # ── Docker Hub ────────────────────────────────────────────────────────────
  echo ""
  echo "--- Docker Hub Configuration ---"
  read -rp "Enter Docker Hub username: " DOCKER_USERNAME
  read -rsp "Enter Docker Hub password/token: " DOCKER_PASSWORD
  echo ""

  REGISTRY_URL="docker.io"
  FULL_IMAGE_NAME="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"

  echo "Logging in to Docker Hub..."
  echo "${DOCKER_PASSWORD}" | docker login --username "${DOCKER_USERNAME}" --password-stdin
  echo "Docker Hub login successful."

else
  echo "ERROR: Invalid registry choice '${REGISTRY_CHOICE}'. Exiting."
  exit 1
fi

echo ""
echo "Full image name: ${FULL_IMAGE_NAME}"
echo ""

# ── Build Docker image ────────────────────────────────────────────────────────
echo "Building Docker image..."
docker build -f "${DOCKERFILE_PATH}" -t "${FULL_IMAGE_NAME}" "${BUILD_CONTEXT}"
echo "Docker image built successfully."

# ── Push Docker image ─────────────────────────────────────────────────────────
echo ""
echo "Pushing Docker image to registry..."
docker push "${FULL_IMAGE_NAME}"
echo ""
echo "=============================================="
echo "  Image pushed successfully!"
echo "  ${FULL_IMAGE_NAME}"
echo "=============================================="
