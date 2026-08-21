@echo off
setlocal enabledelayedexpansion

REM =============================================================================
REM deploy-image.bat — Deploy acme-portal-static to AWS ECS Fargate (Windows)
REM Usage: scripts\deploy-image.bat
REM Prerequisites: aws-cli configured with appropriate IAM permissions
REM =============================================================================

set "SERVICE_NAME=acme-portal-static-service"
set "TASK_FAMILY=acme-portal-static-task"
set "CONTAINER_NAME=acme-portal-static"
set "LOG_GROUP=/ecs/acme-portal-static"
set "TASK_DEF_FILE=ecs\task-definition.json"
set "SERVICE_DEF_FILE=ecs\service-definition.json"

echo ============================================================
echo   acme-portal-static -- AWS ECS Fargate Deployment
echo ============================================================
echo.

REM ── Collect deployment parameters ────────────────────────────────────────────
set /p "AWS_REGION=Enter AWS Region [us-east-1]: "
if "!AWS_REGION!"=="" set "AWS_REGION=us-east-1"

set /p "CLUSTER_NAME=Enter ECS Cluster name [acme-portal-cluster]: "
if "!CLUSTER_NAME!"=="" set "CLUSTER_NAME=acme-portal-cluster"

set /p "IMAGE_URI=Enter ECR Image URI (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/acme-portal-static:latest): "
if "!IMAGE_URI!"=="" (
    echo ERROR: Image URI is required.
    exit /b 1
)

set /p "VPC_ID=Enter VPC ID: "
if "!VPC_ID!"=="" (
    echo ERROR: VPC ID is required.
    exit /b 1
)

set /p "SUBNETS_INPUT=Enter Subnet IDs (comma-separated, e.g. subnet-aaa,subnet-bbb): "
if "!SUBNETS_INPUT!"=="" (
    echo ERROR: At least one subnet ID is required.
    exit /b 1
)

set /p "SECURITY_GROUP=Enter Security Group ID: "
if "!SECURITY_GROUP!"=="" (
    echo ERROR: Security Group ID is required.
    exit /b 1
)

REM Parse subnets
for /f "tokens=1,2 delims=," %%a in ("!SUBNETS_INPUT!") do (
    set "SUBNET_1=%%a"
    set "SUBNET_2=%%b"
)
if "!SUBNET_2!"=="" set "SUBNET_2=!SUBNET_1!"

REM ── Get AWS Account ID ────────────────────────────────────────────────────────
echo.
echo Fetching AWS Account ID...
for /f "delims=" %%i in ('aws sts get-caller-identity --query Account --output text') do set "ACCOUNT_ID=%%i"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to get AWS Account ID. Check your AWS CLI configuration.
    exit /b 1
)
echo Account ID: !ACCOUNT_ID!

REM ── Ensure CloudWatch log group exists ───────────────────────────────────────
echo.
echo Ensuring CloudWatch log group '!LOG_GROUP!' exists...
aws logs create-log-group --log-group-name "!LOG_GROUP!" --region "!AWS_REGION!" >nul 2>&1
echo Log group ready.

REM ── Ensure ECS cluster exists ────────────────────────────────────────────────
echo.
echo Checking ECS cluster '!CLUSTER_NAME!'...
for /f "delims=" %%i in ('aws ecs describe-clusters --clusters "!CLUSTER_NAME!" --region "!AWS_REGION!" --query "clusters[0].status" --output text 2^>nul') do set "CLUSTER_STATUS=%%i"
if not "!CLUSTER_STATUS!"=="ACTIVE" (
    echo Creating ECS cluster '!CLUSTER_NAME!'...
    aws ecs create-cluster --cluster-name "!CLUSTER_NAME!" --region "!AWS_REGION!"
    if !ERRORLEVEL! neq 0 (
        echo ERROR: Failed to create ECS cluster.
        exit /b 1
    )
)
echo ECS cluster ready.

REM ── Load balancer prompt ──────────────────────────────────────────────────────
echo.
set /p "NEED_ALB=Do you need an Application Load Balancer for this service? (y/n) [n]: "
if "!NEED_ALB!"=="" set "NEED_ALB=n"

set "TARGET_GROUP_ARN="
set "ALB_DNS="

if /i "!NEED_ALB!"=="y" (
    echo.
    echo Creating Application Load Balancer...

    set "ALB_NAME=acme-portal-static-alb"
    set "TG_NAME=acme-portal-static-tg"

    for /f "delims=" %%i in ('aws elbv2 create-load-balancer --name "!ALB_NAME!" --subnets "!SUBNET_1!" "!SUBNET_2!" --security-groups "!SECURITY_GROUP!" --scheme internet-facing --type application --region "!AWS_REGION!" --query "LoadBalancers[0].LoadBalancerArn" --output text') do set "ALB_ARN=%%i"
    if !ERRORLEVEL! neq 0 (
        echo ERROR: Failed to create ALB.
        exit /b 1
    )
    echo ALB ARN: !ALB_ARN!

    for /f "delims=" %%i in ('aws elbv2 describe-load-balancers --load-balancer-arns "!ALB_ARN!" --region "!AWS_REGION!" --query "LoadBalancers[0].DNSName" --output text') do set "ALB_DNS=%%i"

    for /f "delims=" %%i in ('aws elbv2 create-target-group --name "!TG_NAME!" --protocol HTTP --port 8080 --vpc-id "!VPC_ID!" --target-type ip --health-check-path "/api/health" --health-check-interval-seconds 30 --healthy-threshold-count 2 --unhealthy-threshold-count 3 --region "!AWS_REGION!" --query "TargetGroups[0].TargetGroupArn" --output text') do set "TARGET_GROUP_ARN=%%i"
    if !ERRORLEVEL! neq 0 (
        echo ERROR: Failed to create Target Group.
        exit /b 1
    )
    echo Target Group ARN: !TARGET_GROUP_ARN!

    aws elbv2 create-listener --load-balancer-arn "!ALB_ARN!" --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=!TARGET_GROUP_ARN!" --region "!AWS_REGION!" >nul
    echo ALB listener created.
)

REM ── Prepare task definition JSON ─────────────────────────────────────────────
echo.
echo Preparing task definition...
copy /Y "!TASK_DEF_FILE!" "%TEMP%\task-definition-deploy.json" >nul

powershell -NoProfile -Command ^
  "(Get-Content '%TEMP%\task-definition-deploy.json') -replace '{{ACCOUNT_ID}}','!ACCOUNT_ID!' -replace '{{AWS_REGION}}','!AWS_REGION!' -replace '{{IMAGE_URI}}','!IMAGE_URI!' | Set-Content '%TEMP%\task-definition-deploy.json'"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to prepare task definition.
    exit /b 1
)

REM ── Register task definition ──────────────────────────────────────────────────
echo Registering ECS task definition...
for /f "delims=" %%i in ('aws ecs register-task-definition --cli-input-json "file://%TEMP%\task-definition-deploy.json" --region "!AWS_REGION!" --query "taskDefinition.taskDefinitionArn" --output text') do set "TASK_DEF_ARN=%%i"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to register task definition.
    exit /b 1
)
echo Task definition registered: !TASK_DEF_ARN!

REM ── Prepare service definition JSON ──────────────────────────────────────────
echo.
echo Preparing service definition...
copy /Y "!SERVICE_DEF_FILE!" "%TEMP%\service-definition-deploy.json" >nul

powershell -NoProfile -Command ^
  "(Get-Content '%TEMP%\service-definition-deploy.json') -replace '{{CLUSTER_NAME}}','!CLUSTER_NAME!' -replace '{{SUBNET_1}}','!SUBNET_1!' -replace '{{SUBNET_2}}','!SUBNET_2!' -replace '{{SECURITY_GROUP}}','!SECURITY_GROUP!' | Set-Content '%TEMP%\service-definition-deploy.json'"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to prepare service definition.
    exit /b 1
)

REM ── Create or update ECS service ─────────────────────────────────────────────
echo.
echo Checking if ECS service '!SERVICE_NAME!' exists...
for /f "delims=" %%i in ('aws ecs describe-services --cluster "!CLUSTER_NAME!" --services "!SERVICE_NAME!" --region "!AWS_REGION!" --query "services[?status!='INACTIVE'].serviceName" --output text 2^>nul') do set "EXISTING_SERVICE=%%i"

if "!EXISTING_SERVICE!"=="" (
    echo Creating new ECS service '!SERVICE_NAME!'...
    aws ecs create-service --cli-input-json "file://%TEMP%\service-definition-deploy.json" --region "!AWS_REGION!"
    if !ERRORLEVEL! neq 0 (
        echo ERROR: Failed to create ECS service.
        exit /b 1
    )
    echo ECS service created.
) else (
    echo Updating existing ECS service '!SERVICE_NAME!'...
    aws ecs update-service --cluster "!CLUSTER_NAME!" --service "!SERVICE_NAME!" --task-definition "!TASK_DEF_ARN!" --region "!AWS_REGION!" >nul
    if !ERRORLEVEL! neq 0 (
        echo ERROR: Failed to update ECS service.
        exit /b 1
    )
    echo ECS service updated.
)

REM ── Wait for service stability ────────────────────────────────────────────────
echo.
echo Waiting for ECS service to stabilize (this may take a few minutes)...
aws ecs wait services-stable --cluster "!CLUSTER_NAME!" --services "!SERVICE_NAME!" --region "!AWS_REGION!"
if !ERRORLEVEL! neq 0 (
    echo WARNING: Service did not stabilize within the expected time. Check ECS console.
)
echo ECS service is stable.

REM ── Verify deployment ─────────────────────────────────────────────────────────
echo.
echo Verifying deployment...
aws ecs describe-services --cluster "!CLUSTER_NAME!" --services "!SERVICE_NAME!" --region "!AWS_REGION!" --query "services[0].{Status:status,Running:runningCount,Desired:desiredCount,Pending:pendingCount}" --output table

echo.
echo ============================================================
echo   Deployment Complete!
echo ============================================================
echo   Service:       !SERVICE_NAME!
echo   Cluster:       !CLUSTER_NAME!
echo   Region:        !AWS_REGION!
echo   Task Def ARN:  !TASK_DEF_ARN!
echo   Log Group:     !LOG_GROUP!
if not "!ALB_DNS!"=="" (
    echo   ALB DNS:       http://!ALB_DNS!
)
echo.
echo   View logs:
echo   aws logs tail !LOG_GROUP! --follow --region !AWS_REGION!
echo ============================================================

endlocal
