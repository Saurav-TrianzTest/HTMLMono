@echo off
setlocal enabledelayedexpansion

REM =============================================================================
REM build-push.bat — Build and push Docker image for acme-portal-static
REM Supports: AWS ECR and Docker Hub
REM Usage: scripts\build-push.bat
REM Run from repository root directory.
REM =============================================================================

set "PROJECT_NAME=acme-portal-static"
set "DOCKERFILE_PATH=Dockerfile"
set "BUILD_CONTEXT=."

echo ==============================================
echo   acme-portal-static -- Docker Build ^& Push
echo ==============================================
echo.

REM ── Tag sanitization via PowerShell ──────────────────────────────────────────
for /f "delims=" %%i in ('powershell -NoProfile -Command "$n='%PROJECT_NAME%'; $n=$n.ToLower() -replace '[^a-z0-9]+','-'; $n=$n.Trim('-'); if($n -eq ''){$n='app'}; $n"') do set "IMAGE_NAME=%%i"
echo Image name (sanitized): !IMAGE_NAME!
echo.

REM ── Prompt for image tag ──────────────────────────────────────────────────────
set /p "IMAGE_TAG_INPUT=Enter image tag [latest]: "
if "!IMAGE_TAG_INPUT!"=="" set "IMAGE_TAG_INPUT=latest"
for /f "delims=" %%i in ('powershell -NoProfile -Command "$t='!IMAGE_TAG_INPUT!'; $t=$t.ToLower() -replace '[^a-z0-9]+','-'; $t=$t.Trim('-'); if($t -eq ''){$t='latest'}; $t"') do set "IMAGE_TAG=%%i"
echo Image tag: !IMAGE_TAG!
echo.

REM ── Registry selection ────────────────────────────────────────────────────────
echo Select container registry:
echo   1. AWS ECR
echo   2. Docker Hub
set /p "REGISTRY_CHOICE=Enter choice [1]: "
if "!REGISTRY_CHOICE!"=="" set "REGISTRY_CHOICE=1"

if "!REGISTRY_CHOICE!"=="1" goto :ecr_setup
if "!REGISTRY_CHOICE!"=="2" goto :dockerhub_setup
echo ERROR: Invalid registry choice. Exiting.
exit /b 1

:ecr_setup
echo.
echo --- AWS ECR Configuration ---
set /p "AWS_REGION=Enter AWS Region [us-east-1]: "
if "!AWS_REGION!"=="" set "AWS_REGION=us-east-1"

set /p "AWS_ACCOUNT_ID=Enter AWS Account ID (leave blank to auto-detect): "
if "!AWS_ACCOUNT_ID!"=="" (
    echo Fetching AWS Account ID from STS...
    for /f "delims=" %%i in ('aws sts get-caller-identity --query Account --output text') do set "AWS_ACCOUNT_ID=%%i"
    echo Account ID: !AWS_ACCOUNT_ID!
)

set "ECR_REPO=!IMAGE_NAME!"
set "REGISTRY_URL=!AWS_ACCOUNT_ID!.dkr.ecr.!AWS_REGION!.amazonaws.com"
set "FULL_IMAGE_NAME=!REGISTRY_URL!/!ECR_REPO!:!IMAGE_TAG!"

echo.
echo Logging in to Amazon ECR...
aws ecr get-login-password --region !AWS_REGION! | docker login --username AWS --password-stdin !REGISTRY_URL!
if !ERRORLEVEL! neq 0 (
    echo ERROR: ECR login failed.
    exit /b 1
)
echo ECR login successful.

echo Checking if ECR repository '!ECR_REPO!' exists...
aws ecr describe-repositories --repository-names !ECR_REPO! --region !AWS_REGION! >nul 2>&1
if !ERRORLEVEL! neq 0 (
    echo Creating ECR repository '!ECR_REPO!'...
    aws ecr create-repository --repository-name !ECR_REPO! --region !AWS_REGION!
    if !ERRORLEVEL! neq 0 (
        echo ERROR: Failed to create ECR repository.
        exit /b 1
    )
)
echo ECR repository ready.
goto :build

:dockerhub_setup
echo.
echo --- Docker Hub Configuration ---
set /p "DOCKER_USERNAME=Enter Docker Hub username: "
set /p "DOCKER_PASSWORD=Enter Docker Hub password/token: "

set "REGISTRY_URL=docker.io"
set "FULL_IMAGE_NAME=!DOCKER_USERNAME!/!IMAGE_NAME!:!IMAGE_TAG!"

echo Logging in to Docker Hub...
echo !DOCKER_PASSWORD! | docker login --username !DOCKER_USERNAME! --password-stdin
if !ERRORLEVEL! neq 0 (
    echo ERROR: Docker Hub login failed.
    exit /b 1
)
echo Docker Hub login successful.
goto :build

:build
echo.
echo Full image name: !FULL_IMAGE_NAME!
echo.

REM ── Build Docker image ────────────────────────────────────────────────────────
echo Building Docker image...
docker build -f "!DOCKERFILE_PATH!" -t "!FULL_IMAGE_NAME!" "!BUILD_CONTEXT!"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Docker build failed.
    exit /b 1
)
echo Docker image built successfully.

REM ── Push Docker image ─────────────────────────────────────────────────────────
echo.
echo Pushing Docker image to registry...
docker push "!FULL_IMAGE_NAME!"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Docker push failed.
    exit /b 1
)

echo.
echo ==============================================
echo   Image pushed successfully!
echo   !FULL_IMAGE_NAME!
echo ==============================================

endlocal
