#!/bin/bash
# =============================================================================
# deploy-image.sh — Deploy acme-portal-static to AWS ECS Fargate
# Usage: ./scripts/deploy-image.sh
# Prerequisites: aws-cli configured with appropriate IAM permissions
# =============================================================================

set -e
set -o pipefail

SERVICE_NAME="acme-portal-static-service"
TASK_FAMILY="acme-portal-static-task"
CONTAINER_NAME="acme-portal-static"
LOG_GROUP="/ecs/acme-portal-static"
TASK_DEF_FILE="ecs/task-definition.json"
SERVICE_DEF_FILE="ecs/service-definition.json"

echo "============================================================"
echo "  acme-portal-static — AWS ECS Fargate Deployment"
echo "============================================================"
echo ""

# ── Collect deployment parameters ────────────────────────────────────────────
read -rp "Enter AWS Region [us-east-1]: " AWS_REGION
AWS_REGION="${AWS_REGION:-us-east-1}"

read -rp "Enter ECS Cluster name [acme-portal-cluster]: " CLUSTER_NAME
CLUSTER_NAME="${CLUSTER_NAME:-acme-portal-cluster}"

read -rp "Enter ECR Image URI (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/acme-portal-static:latest): " IMAGE_URI
if [ -z "$IMAGE_URI" ]; then
  echo "ERROR: Image URI is required."
  exit 1
fi

read -rp "Enter VPC ID: " VPC_ID
if [ -z "$VPC_ID" ]; then
  echo "ERROR: VPC ID is required."
  exit 1
fi

read -rp "Enter Subnet IDs (comma-separated, e.g. subnet-aaa,subnet-bbb): " SUBNETS_INPUT
if [ -z "$SUBNETS_INPUT" ]; then
  echo "ERROR: At least one subnet ID is required."
  exit 1
fi

read -rp "Enter Security Group ID: " SECURITY_GROUP
if [ -z "$SECURITY_GROUP" ]; then
  echo "ERROR: Security Group ID is required."
  exit 1
fi

# Parse subnets
SUBNET_1=$(echo "$SUBNETS_INPUT" | cut -d',' -f1 | tr -d ' ')
SUBNET_2=$(echo "$SUBNETS_INPUT" | cut -d',' -f2 | tr -d ' ')
if [ -z "$SUBNET_2" ]; then
  SUBNET_2="$SUBNET_1"
fi

# ── Get AWS Account ID ────────────────────────────────────────────────────────
echo ""
echo "Fetching AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: ${ACCOUNT_ID}"

# ── Ensure CloudWatch log group exists ───────────────────────────────────────
echo ""
echo "Ensuring CloudWatch log group '${LOG_GROUP}' exists..."
aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${AWS_REGION}" 2>/dev/null || true
echo "Log group ready."

# ── Ensure ECS cluster exists ────────────────────────────────────────────────
echo ""
echo "Checking ECS cluster '${CLUSTER_NAME}'..."
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query "clusters[0].status" --output text 2>/dev/null || echo "MISSING")
if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
  echo "Creating ECS cluster '${CLUSTER_NAME}'..."
  aws ecs create-cluster --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}"
fi
echo "ECS cluster ready."

# ── Load balancer prompt ──────────────────────────────────────────────────────
echo ""
read -rp "Do you need an Application Load Balancer for this service? (y/n) [n]: " NEED_ALB
NEED_ALB="${NEED_ALB:-n}"

TARGET_GROUP_ARN=""
ALB_DNS=""

if [ "$NEED_ALB" = "y" ] || [ "$NEED_ALB" = "Y" ]; then
  echo ""
  echo "Creating Application Load Balancer..."

  ALB_NAME="acme-portal-static-alb"
  TG_NAME="acme-portal-static-tg"

  # Create ALB
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${ALB_NAME}" \
    --subnets ${SUBNET_1} ${SUBNET_2} \
    --security-groups "${SECURITY_GROUP}" \
    --scheme internet-facing \
    --type application \
    --region "${AWS_REGION}" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text)
  echo "ALB ARN: ${ALB_ARN}"

  ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "${ALB_ARN}" \
    --region "${AWS_REGION}" \
    --query "LoadBalancers[0].DNSName" \
    --output text)

  # Create Target Group (target-type ip required for Fargate awsvpc mode)
  TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --name "${TG_NAME}" \
    --protocol HTTP \
    --port 8080 \
    --vpc-id "${VPC_ID}" \
    --target-type ip \
    --health-check-path "/api/health" \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region "${AWS_REGION}" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text)
  echo "Target Group ARN: ${TARGET_GROUP_ARN}"

  # Create listener
  aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="${TARGET_GROUP_ARN}" \
    --region "${AWS_REGION}" >/dev/null
  echo "ALB listener created."
fi

# ── Prepare task definition JSON ─────────────────────────────────────────────
echo ""
echo "Preparing task definition..."
cp "${TASK_DEF_FILE}" /tmp/task-definition-deploy.json

sed -i "s|{{ACCOUNT_ID}}|${ACCOUNT_ID}|g"     /tmp/task-definition-deploy.json
sed -i "s|{{AWS_REGION}}|${AWS_REGION}|g"     /tmp/task-definition-deploy.json
sed -i "s|{{IMAGE_URI}}|${IMAGE_URI}|g"       /tmp/task-definition-deploy.json

# ── Register task definition ──────────────────────────────────────────────────
echo "Registering ECS task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-definition-deploy.json \
  --region "${AWS_REGION}" \
  --query "taskDefinition.taskDefinitionArn" \
  --output text)
echo "Task definition registered: ${TASK_DEF_ARN}"

# ── Prepare service definition JSON ──────────────────────────────────────────
echo ""
echo "Preparing service definition..."
cp "${SERVICE_DEF_FILE}" /tmp/service-definition-deploy.json

sed -i "s|{{CLUSTER_NAME}}|${CLUSTER_NAME}|g"     /tmp/service-definition-deploy.json
sed -i "s|{{SUBNET_1}}|${SUBNET_1}|g"             /tmp/service-definition-deploy.json
sed -i "s|{{SUBNET_2}}|${SUBNET_2}|g"             /tmp/service-definition-deploy.json
sed -i "s|{{SECURITY_GROUP}}|${SECURITY_GROUP}|g" /tmp/service-definition-deploy.json

# Add load balancer configuration if ALB was created
if [ -n "$TARGET_GROUP_ARN" ]; then
  # Inject loadBalancers and healthCheckGracePeriodSeconds into service JSON
  python3 - <<PYEOF
import json, sys

with open('/tmp/service-definition-deploy.json', 'r') as f:
    svc = json.load(f)

svc['loadBalancers'] = [{
    'targetGroupArn': '${TARGET_GROUP_ARN}',
    'containerName': '${CONTAINER_NAME}',
    'containerPort': 8080
}]
svc['healthCheckGracePeriodSeconds'] = 300

with open('/tmp/service-definition-deploy.json', 'w') as f:
    json.dump(svc, f, indent=2)
PYEOF
fi

# ── Create or update ECS service ─────────────────────────────────────────────
echo ""
echo "Checking if ECS service '${SERVICE_NAME}' exists..."
EXISTING_SERVICE=$(aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services "${SERVICE_NAME}" \
  --region "${AWS_REGION}" \
  --query "services[?status!='INACTIVE'].serviceName" \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_SERVICE" ] || [ "$EXISTING_SERVICE" = "None" ]; then
  echo "Creating new ECS service '${SERVICE_NAME}'..."
  aws ecs create-service \
    --cli-input-json file:///tmp/service-definition-deploy.json \
    --region "${AWS_REGION}"
  echo "ECS service created."
else
  echo "Updating existing ECS service '${SERVICE_NAME}'..."
  aws ecs update-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${SERVICE_NAME}" \
    --task-definition "${TASK_DEF_ARN}" \
    --region "${AWS_REGION}" >/dev/null
  echo "ECS service updated."
fi

# ── Wait for service stability ────────────────────────────────────────────────
echo ""
echo "Waiting for ECS service to stabilize (this may take a few minutes)..."
aws ecs wait services-stable \
  --cluster "${CLUSTER_NAME}" \
  --services "${SERVICE_NAME}" \
  --region "${AWS_REGION}"
echo "ECS service is stable."

# ── Verify deployment ─────────────────────────────────────────────────────────
echo ""
echo "Verifying deployment..."
aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services "${SERVICE_NAME}" \
  --region "${AWS_REGION}" \
  --query "services[0].{Status:status,Running:runningCount,Desired:desiredCount,Pending:pendingCount}" \
  --output table

echo ""
echo "============================================================"
echo "  Deployment Complete!"
echo "============================================================"
echo "  Service:       ${SERVICE_NAME}"
echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Region:        ${AWS_REGION}"
echo "  Task Def ARN:  ${TASK_DEF_ARN}"
echo "  Log Group:     ${LOG_GROUP}"
if [ -n "$ALB_DNS" ]; then
  echo "  ALB DNS:       http://${ALB_DNS}"
fi
echo ""
echo "  View logs:"
echo "  aws logs tail ${LOG_GROUP} --follow --region ${AWS_REGION}"
echo ""
echo "  Troubleshooting:"
echo "  aws ecs list-tasks --cluster ${CLUSTER_NAME} --service-name ${SERVICE_NAME} --region ${AWS_REGION}"
echo "  aws ecs describe-tasks --cluster ${CLUSTER_NAME} --tasks <TASK_ARN> --region ${AWS_REGION}"
echo "============================================================"
