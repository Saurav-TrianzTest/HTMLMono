# Deployment Guide — acme-portal-static (HTMLMono2)

## Overview

This guide covers building, pushing, and deploying the **acme-portal-static** application to **AWS ECS Fargate**.

The application is a hybrid container:
- **nginx** serves the static HTML frontend on port **8080**
- **Java backend** (JDK 17, plain `com.sun.net.httpserver`) serves `/api/health` on port **8081** (proxied by nginx)

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Project Structure](#project-structure)
3. [Local Development with Docker Compose](#local-development-with-docker-compose)
4. [Build and Push Docker Image](#build-and-push-docker-image)
5. [AWS ECS Fargate Prerequisites](#aws-ecs-fargate-prerequisites)
6. [ECS Task Definition Explained](#ecs-task-definition-explained)
7. [ECS Service Configuration](#ecs-service-configuration)
8. [ECS Fargate Deployment Walkthrough](#ecs-fargate-deployment-walkthrough)
9. [Environment Variables and SSM/Secrets Manager Integration](#environment-variables-and-ssmsecrets-manager-integration)
10. [ECS-Specific Troubleshooting](#ecs-specific-troubleshooting)
11. [Scaling and Management](#scaling-and-management)
12. [Security Considerations](#security-considerations)
13. [Java-Specific Notes](#java-specific-notes)

---

## Prerequisites

### Local Development
- Docker Desktop 24+ or Docker Engine 24+
- Docker Compose v2.20+
- Java 17 (for local builds without Docker)
- Apache Maven 3.9+ (for local builds without Docker)
- AWS CLI v2 (for ECR push and ECS deployment)

### AWS Requirements
- AWS account with appropriate IAM permissions
- AWS CLI configured: `aws configure`
- ECR repository (auto-created by `build-push.sh`)
- VPC with at least 2 subnets in different Availability Zones
- Security group allowing inbound TCP on port **8080**
- IAM roles: `ecsTaskExecutionRole` and `ecsTaskRole`

---

## Project Structure

```
HTMLMono2/
├── Dockerfile                    # Multi-stage build (Maven builder + nginx/JDK runtime)
├── docker-compose.yml            # Local development compose file
├── .dockerignore                 # Excludes build artifacts and wrapper files
├── docker-entrypoint.sh          # Runtime config injection script
├── pom.xml                       # Maven build descriptor (Java 17)
├── src/
│   └── main/java/com/trianz/acmeportal/
│       ├── Application.java      # JDK HttpServer on port 8081
│       └── HealthHandler.java    # GET /api/health → {"status":"ok"}
├── index.html                    # Static HTML frontend
├── pages/, partials/, forms/,    # Additional HTML assets
├── app/, assets/                 # SPA shell and CSS/JS assets
├── ecs/
│   ├── task-definition.json      # ECS Fargate task definition
│   └── service-definition.json   # ECS Fargate service definition
├── scripts/
│   ├── build-push.sh             # Linux/macOS: build and push to ECR/Docker Hub
│   ├── build-push.bat            # Windows: build and push to ECR/Docker Hub
│   ├── deploy-image.sh           # Linux/macOS: deploy to ECS Fargate
│   └── deploy-image.bat          # Windows: deploy to ECS Fargate
└── docs/
    └── DEPLOYMENT.md             # This file
```

---

## Local Development with Docker Compose

### 1. Build and start the application

```bash
# From the project root (HTMLMono2/)
docker compose up --build
```

### 2. Access the application

- **Frontend**: http://localhost:8080
- **Health check**: http://localhost:8080/api/health

### 3. Override environment variables locally

Create a `.env` file in the project root:

```env
NUXT_PUBLIC_API_BASE=http://localhost:8080
NUXT_PUBLIC_APP_TITLE=Acme Portal (Dev)
NUXT_APP_ENV=development
RUNTIME_API_BASE_URL=http://localhost:8080
RUNTIME_APP_ENV=development
```

Then run:

```bash
docker compose --env-file .env up --build
```

### 4. View logs

```bash
docker compose logs -f acme-portal-static
```

### 5. Stop the application

```bash
docker compose down
```

---

## Build and Push Docker Image

### Linux/macOS

```bash
chmod +x scripts/build-push.sh
./scripts/build-push.sh
```

### Windows

```cmd
scripts\build-push.bat
```

The script will prompt you to:
1. Select registry type (AWS ECR or Docker Hub)
2. Enter registry credentials/details
3. Enter an image tag (defaults to `latest`)

The script automatically:
- Sanitizes the image name to lowercase with hyphens
- Creates the ECR repository if it does not exist (ECR only)
- Builds the Docker image from the project root
- Pushes the image to the selected registry

### Manual build and push (ECR example)

```bash
# Authenticate to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789.dkr.ecr.us-east-1.amazonaws.com

# Build
docker build -t 123456789.dkr.ecr.us-east-1.amazonaws.com/acme-portal-static:latest .

# Push
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/acme-portal-static:latest
```

---

## AWS ECS Fargate Prerequisites

### 1. IAM Roles

#### ecsTaskExecutionRole
Required for ECS to pull images from ECR and write logs to CloudWatch.

```bash
# Create the role (if it doesn't exist)
aws iam create-role \
  --role-name ecsTaskExecutionRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

# Attach the managed policy
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

#### ecsTaskRole
Required for the application to access SSM Parameter Store and Secrets Manager.

```bash
aws iam create-role \
  --role-name ecsTaskRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

# Attach SSM and Secrets Manager read permissions
aws iam attach-role-policy \
  --role-name ecsTaskRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess

aws iam attach-role-policy \
  --role-name ecsTaskRole \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
```

### 2. VPC and Networking

Ensure you have:
- A VPC with DNS resolution enabled
- At least **2 public or private subnets** in different Availability Zones
- A **security group** with inbound rule: TCP port **8080** from `0.0.0.0/0` (or your ALB security group)
- Outbound rule: All traffic (for ECR image pull and CloudWatch logs)

### 3. CloudWatch Log Group

```bash
aws logs create-log-group \
  --log-group-name /ecs/acme-portal-static \
  --region us-east-1
```

### 4. SSM Parameters (for runtime config injection)

```bash
# Create SSM parameters used by the application
aws ssm put-parameter --name /acme/api-base --value "https://api.example.com" --type String --region us-east-1
aws ssm put-parameter --name /acme/cdn-base-url --value "https://cdn.example.com" --type String --region us-east-1
aws ssm put-parameter --name /acme/admin-console-url --value "https://admin.example.com" --type String --region us-east-1
aws ssm put-parameter --name /acme/dashboard/api-base-url --value "https://api.example.com" --type String --region us-east-1
aws ssm put-parameter --name /acme/dashboard/app-env --value "production" --type String --region us-east-1
aws ssm put-parameter --name /acme/dashboard/feature-flags --value "{}" --type String --region us-east-1

# Create Secrets Manager secret for telemetry URL
aws secretsmanager create-secret \
  --name acme/telemetry-base-url \
  --secret-string "https://telemetry.example.com" \
  --region us-east-1
```

---

## ECS Task Definition Explained

File: `ecs/task-definition.json`

| Field | Value | Notes |
|-------|-------|-------|
| `family` | `acme-portal-static-task` | Task definition family name |
| `requiresCompatibilities` | `["FARGATE"]` | Fargate launch type required |
| `networkMode` | `awsvpc` | Required for Fargate |
| `cpu` | `"512"` | 0.5 vCPU |
| `memory` | `"1024"` | 1 GB RAM |
| `executionRoleArn` | `ecsTaskExecutionRole` | ECR pull + CloudWatch logs |
| `taskRoleArn` | `ecsTaskRole` | SSM + Secrets Manager access |

### Container Definition

| Field | Value |
|-------|-------|
| `name` | `acme-portal-static` |
| `image` | `{{IMAGE_URI}}` (replaced at deploy time) |
| `containerPort` | `8080` |
| `logDriver` | `awslogs` → `/ecs/acme-portal-static` |

### Valid Fargate CPU/Memory Combinations

| CPU | Valid Memory Options |
|-----|---------------------|
| 256 | 512, 1024, 2048 MB |
| **512** | **1024**, 2048, 3072, 4096 MB |
| 1024 | 2048–8192 MB |
| 2048 | 4096–16384 MB |
| 4096 | 8192–30720 MB |

---

## ECS Service Configuration

File: `ecs/service-definition.json`

| Field | Value |
|-------|-------|
| `serviceName` | `acme-portal-static-service` |
| `launchType` | `FARGATE` |
| `desiredCount` | `2` |
| `assignPublicIp` | `ENABLED` |
| `maximumPercent` | `200` |
| `minimumHealthyPercent` | `50` |

---

## ECS Fargate Deployment Walkthrough

### Option A: Automated (recommended)

```bash
# Linux/macOS
chmod +x scripts/deploy-image.sh
./scripts/deploy-image.sh
```

```cmd
REM Windows
scripts\deploy-image.bat
```

The script will prompt for:
- AWS Region
- ECS Cluster name
- ECR Image URI
- VPC ID
- Subnet IDs (comma-separated)
- Security Group ID
- Whether to create an Application Load Balancer

### Option B: Manual deployment

#### Step 1: Register the task definition

```bash
# Replace placeholders
sed -e 's|{{ACCOUNT_ID}}|123456789|g' \
    -e 's|{{AWS_REGION}}|us-east-1|g' \
    -e 's|{{IMAGE_URI}}|123456789.dkr.ecr.us-east-1.amazonaws.com/acme-portal-static:latest|g' \
    ecs/task-definition.json > /tmp/task-def.json

TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-def.json \
  --region us-east-1 \
  --query "taskDefinition.taskDefinitionArn" \
  --output text)
echo "Task Definition ARN: $TASK_DEF_ARN"
```

#### Step 2: Create the ECS cluster (if needed)

```bash
aws ecs create-cluster --cluster-name acme-portal-cluster --region us-east-1
```

#### Step 3: Create the ECS service

```bash
sed -e 's|{{CLUSTER_NAME}}|acme-portal-cluster|g' \
    -e 's|{{SUBNET_1}}|subnet-xxxxxxxx|g' \
    -e 's|{{SUBNET_2}}|subnet-yyyyyyyy|g' \
    -e 's|{{SECURITY_GROUP}}|sg-zzzzzzzz|g' \
    ecs/service-definition.json > /tmp/service-def.json

aws ecs create-service \
  --cli-input-json file:///tmp/service-def.json \
  --region us-east-1
```

#### Step 4: Wait for stability

```bash
aws ecs wait services-stable \
  --cluster acme-portal-cluster \
  --services acme-portal-static-service \
  --region us-east-1
```

#### Step 5: Verify

```bash
aws ecs describe-services \
  --cluster acme-portal-cluster \
  --services acme-portal-static-service \
  --region us-east-1 \
  --query "services[0].{Status:status,Running:runningCount,Desired:desiredCount}"
```

---

## Environment Variables and SSM/Secrets Manager Integration

The application uses `docker-entrypoint.sh` to substitute runtime configuration placeholders in HTML files at container startup. Values are injected via ECS task definition `secrets` block from AWS SSM Parameter Store and Secrets Manager.

| Variable | Source | Purpose |
|----------|--------|---------|
| `NUXT_PUBLIC_API_BASE` | SSM: `/acme/api-base` | Nuxt 3 Nitro SSR API base URL |
| `NUXT_PUBLIC_APP_TITLE` | Environment | Application title |
| `NUXT_APP_ENV` | Environment | Application environment |
| `TELEMETRY_BASE_URL` | Secrets Manager: `acme/telemetry-base-url` | Telemetry service URL |
| `CDN_BASE_URL` | SSM: `/acme/cdn-base-url` | CloudFront CDN URL |
| `RUNTIME_API_BASE_URL` | SSM: `/acme/dashboard/api-base-url` | Runtime API base URL |
| `RUNTIME_APP_ENV` | SSM: `/acme/dashboard/app-env` | Runtime environment |
| `RUNTIME_FEATURE_FLAGS` | SSM: `/acme/dashboard/feature-flags` | Feature flags JSON |
| `ADMIN_CONSOLE_URL` | SSM: `/acme/admin-console-url` | Admin console URL |
| `JAVA_OPTS` | Environment | JVM memory settings |

---

## ECS-Specific Troubleshooting

### Task fails to start

```bash
# List stopped tasks
aws ecs list-tasks \
  --cluster acme-portal-cluster \
  --desired-status STOPPED \
  --region us-east-1

# Describe stopped task for error details
aws ecs describe-tasks \
  --cluster acme-portal-cluster \
  --tasks <TASK_ARN> \
  --region us-east-1 \
  --query "tasks[0].stoppedReason"
```

### Image pull failure

- Verify `ecsTaskExecutionRole` has `AmazonECSTaskExecutionRolePolicy` attached
- Confirm the ECR repository exists and the image tag is correct
- Check that the task's security group allows outbound HTTPS (port 443) for ECR

### Network connectivity issues

- Ensure subnets have a route to the internet (via Internet Gateway or NAT Gateway)
- For private subnets, ensure VPC endpoints exist for ECR, CloudWatch Logs, and SSM
- Verify security group inbound rules allow traffic on port 8080

### SSM/Secrets Manager access failure

- Verify `ecsTaskRole` has read permissions for SSM and Secrets Manager
- Confirm SSM parameter paths match exactly (case-sensitive)
- Check that the task's security group allows outbound HTTPS for SSM endpoints

### CPU/Memory errors

- Use only valid Fargate CPU/memory combinations (see table above)
- Default: cpu=512, memory=1024 — increase if tasks are OOM-killed
- Monitor with: `aws cloudwatch get-metric-statistics --namespace AWS/ECS ...`

### View application logs

```bash
aws logs tail /ecs/acme-portal-static --follow --region us-east-1
```

---

## Scaling and Management

### Manual scaling

```bash
aws ecs update-service \
  --cluster acme-portal-cluster \
  --service acme-portal-static-service \
  --desired-count 4 \
  --region us-east-1
```

### Auto Scaling

```bash
# Register scalable target
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/acme-portal-cluster/acme-portal-static-service \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 \
  --max-capacity 10

# Create CPU-based scaling policy
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/acme-portal-cluster/acme-portal-static-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name acme-portal-cpu-scaling \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
    },
    "ScaleInCooldown": 300,
    "ScaleOutCooldown": 60
  }'
```

### Blue/Green Deployment

Use AWS CodeDeploy with ECS for zero-downtime blue/green deployments:

1. Update `service-definition.json` to use `deploymentController: {"type": "CODE_DEPLOY"}`
2. Create a CodeDeploy application and deployment group targeting the ECS service
3. Use `appspec.yaml` with `TaskDefinition` and `LoadBalancerInfo` sections

### Rolling update (default)

The service definition uses:
- `maximumPercent: 200` — allows double the desired count during deployment
- `minimumHealthyPercent: 50` — keeps at least half the tasks running

---

## Security Considerations

1. **Non-root user**: The Java backend runs as `appuser` (non-root)
2. **No secrets in environment variables**: Use ECS secrets injection from SSM/Secrets Manager
3. **ECR image scanning**: Enable ECR image scanning on push
4. **Security group**: Restrict inbound to ALB security group only (not `0.0.0.0/0`)
5. **VPC**: Deploy in private subnets with NAT Gateway for production
6. **IAM least privilege**: Scope `ecsTaskRole` to specific SSM parameter paths
7. **TLS**: Terminate TLS at the ALB (HTTPS listener with ACM certificate)
8. **Image tags**: Use immutable tags (commit SHA) instead of `latest` in production

---

## Java-Specific Notes

### JVM Configuration

The application uses the following JVM flags (set via `JAVA_OPTS`):

```
-Xmx256m                    # Maximum heap size
-Xms128m                    # Initial heap size
-XX:+UseContainerSupport    # Enable container-aware memory limits
-XX:MaxRAMPercentage=75.0   # Use 75% of container memory for heap
-Djava.net.preferIPv4Stack=true  # Prefer IPv4 (Fargate networking)
```

### Health Endpoint

The Java backend exposes `GET /api/health` returning:
```json
{"status":"ok"}
```

nginx proxies `/api/*` requests to the Java backend on port 8081.

### Startup Time

The JDK `HttpServer` starts in under 1 second. No JVM warm-up period is needed.

### Increasing Memory

If the application requires more memory, update `ecs/task-definition.json`:

```json
"cpu": "512",
"memory": "2048"
```

And update `JAVA_OPTS`:
```
-Xmx1536m -Xms512m -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0
```

### Monitoring

View JVM metrics via CloudWatch Container Insights:

```bash
aws ecs update-cluster-settings \
  --cluster acme-portal-cluster \
  --settings name=containerInsights,value=enabled \
  --region us-east-1
```
