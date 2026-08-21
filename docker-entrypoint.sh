#!/bin/sh
# =============================================================================
# docker-entrypoint.sh
# ECS Fargate Container Entry Point
#
# Rule: cz-html-1011 — Missing Runtime Config Injection Point in HTML
# Purpose: Substitute ${RUNTIME_*} placeholders inside the window.__ENV__
#          script block (injected by the SSM Agent sidecar) with values read
#          from AWS SSM Parameter Store via ECS task definition secrets block,
#          enabling dynamic Kubernetes / ECS Fargate configuration without
#          rebuilding the container image.
#
# Rule: cz-html-1002 — Platform-Specific Path Separators in HTML
# Purpose: Normalize Windows-style backslash path separators in HTML files
#          to Linux-compatible forward slashes before the web server starts.
#
# Rule: cz-html-1007 — Hardcoded Port Numbers in HTML Script/Link Tags
# Purpose: Substitute ${TELEMETRY_BASE_URL} placeholder (injected from AWS
#          Secrets Manager via ECS Fargate task definition secrets block) into
#          HTML files, replacing the original hardcoded localhost:5000 port
#          reference with the runtime-resolved canonical service URL.
#
# Rule: cz-html-1008 — Localhost Resource References in HTML
# Purpose: Substitute ${CDN_BASE_URL} placeholder (CloudFront distribution URL
#          backed by Amazon S3, injected from AWS SSM Parameter Store via ECS
#          Fargate task definition secrets block) into HTML files, replacing all
#          localhost static-asset references with the CDN URL for proper
#          multi-container / Kubernetes service discovery.
#
# Rule: cz-html-1004 — Client-Side Only HTML for SSR Containers (Nuxt 3 Nitro)
# Purpose: Substitute Nuxt 3 Nitro SSR runtime configuration placeholders in
#          HTML templates with values injected from AWS SSM Parameter Store via
#          ECS secrets injection environment variables, enabling proper SSR pod
#          operation on Kubernetes / ECS Fargate without blank pages.
# =============================================================================

set -e

HTML_ROOT="${HTML_ROOT:-/usr/share/nginx/html}"

# ---------------------------------------------------------------------------
# Phase 1 (cz-html-1002): Path normalization
# ---------------------------------------------------------------------------
echo "[entrypoint] Starting path normalization for HTML files in: ${HTML_ROOT}"

find "${HTML_ROOT}" -type f -name "*.html" | while read -r html_file; do
    if grep -qP 'href="[^"]*\\[^"]*"' "${html_file}" 2>/dev/null || \
       grep -qP 'src="[^"]*\\[^"]*"' "${html_file}" 2>/dev/null; then
        echo "[entrypoint] Normalizing paths in: ${html_file}"
        sed -i 's|href="\([^"]*\)\\|href="\1/|g; s|src="\([^"]*\)\\|src="\1/|g' "${html_file}"
        sed -i 's|href="\([^"]*\)\\|href="\1/|g; s|src="\([^"]*\)\\|src="\1/|g' "${html_file}"
    fi
done

echo "[entrypoint] Path normalization complete."

# ---------------------------------------------------------------------------
# Phase 2 (cz-html-1004): Nuxt 3 Nitro SSR runtime config substitution
#
# Environment variables are injected by ECS task definition from AWS SSM
# Parameter Store via the secrets block (secretsFrom / valueFrom).
# Placeholders in the form ${VAR_NAME} inside HTML templates are replaced
# with the resolved SSM values so Nuxt Nitro receives correct runtime config
# and SSR pods render meaningful HTML instead of a blank page.
# ---------------------------------------------------------------------------
echo "[entrypoint] Injecting Nuxt 3 Nitro SSR runtime config from SSM environment variables..."

# Resolve runtime config values (SSM-injected or defaults)
NUXT_PUBLIC_API_BASE="${NUXT_PUBLIC_API_BASE:-}"
NUXT_PUBLIC_APP_TITLE="${NUXT_PUBLIC_APP_TITLE:-Acme App}"
NUXT_APP_ENV="${NUXT_APP_ENV:-production}"

echo "[entrypoint]   NUXT_PUBLIC_API_BASE  = ${NUXT_PUBLIC_API_BASE}"
echo "[entrypoint]   NUXT_PUBLIC_APP_TITLE = ${NUXT_PUBLIC_APP_TITLE}"
echo "[entrypoint]   NUXT_APP_ENV          = ${NUXT_APP_ENV}"

# Substitute placeholders in all HTML files under HTML_ROOT
find "${HTML_ROOT}" -type f -name "*.html" | while read -r html_file; do
    if grep -q '\${NUXT_' "${html_file}" 2>/dev/null; then
        echo "[entrypoint] Substituting SSR runtime config in: ${html_file}"
        # Replace ${NUXT_PUBLIC_API_BASE} placeholder
        sed -i "s|\${NUXT_PUBLIC_API_BASE}|${NUXT_PUBLIC_API_BASE}|g" "${html_file}"
        # Replace ${NUXT_PUBLIC_APP_TITLE} placeholder (including default syntax)
        sed -i "s|\${NUXT_PUBLIC_APP_TITLE:-[^}]*}|${NUXT_PUBLIC_APP_TITLE}|g" "${html_file}"
        sed -i "s|\${NUXT_PUBLIC_APP_TITLE}|${NUXT_PUBLIC_APP_TITLE}|g" "${html_file}"
        # Replace ${NUXT_APP_ENV} placeholder
        sed -i "s|\${NUXT_APP_ENV}|${NUXT_APP_ENV}|g" "${html_file}"
        # Replace title default-value placeholders (e.g. ${NUXT_PUBLIC_APP_TITLE:-App Shell})
        sed -i "s|\${NUXT_PUBLIC_APP_TITLE:-App Shell}|${NUXT_PUBLIC_APP_TITLE}|g" "${html_file}"
        sed -i "s|\${NUXT_PUBLIC_APP_TITLE:-Acme App}|${NUXT_PUBLIC_APP_TITLE}|g" "${html_file}"
    fi
done

echo "[entrypoint] SSR runtime config substitution complete."

# ---------------------------------------------------------------------------
# Phase 3 (cz-html-1007): Telemetry base URL substitution
#
# TELEMETRY_BASE_URL is stored in AWS Secrets Manager and injected into the
# ECS Fargate task definition at runtime via the secrets block:
#
#   ECS Task Definition (secrets block):
#     - name: TELEMETRY_BASE_URL
#       valueFrom: arn:aws:secretsmanager:<REGION>:<ACCOUNT>:secret:acme/telemetry-base-url
#
# The placeholder ${TELEMETRY_BASE_URL} in HTML files is replaced with the
# resolved value so the browser loads telemetry.js from the correct service
# endpoint without any hardcoded port numbers.
# ---------------------------------------------------------------------------
echo "[entrypoint] Injecting TELEMETRY_BASE_URL from AWS Secrets Manager environment variable..."

TELEMETRY_BASE_URL="${TELEMETRY_BASE_URL:-}"

echo "[entrypoint]   TELEMETRY_BASE_URL = ${TELEMETRY_BASE_URL}"

find "${HTML_ROOT}" -type f -name "*.html" | while read -r html_file; do
    if grep -q '\${TELEMETRY_BASE_URL}' "${html_file}" 2>/dev/null; then
        echo "[entrypoint] Substituting TELEMETRY_BASE_URL in: ${html_file}"
        sed -i "s|\${TELEMETRY_BASE_URL}|${TELEMETRY_BASE_URL}|g" "${html_file}"
    fi
done

echo "[entrypoint] TELEMETRY_BASE_URL substitution complete."

# ---------------------------------------------------------------------------
# Phase 4 (cz-html-1008): CDN base URL substitution
#
# CDN_BASE_URL is the CloudFront distribution URL (backed by Amazon S3) and
# is injected into the ECS Fargate task definition at runtime via the secrets
# block or SSM Parameter Store:
#
#   ECS Task Definition (secrets block):
#     - name: CDN_BASE_URL
#       valueFrom: arn:aws:ssm:<REGION>:<ACCOUNT>:parameter/acme/cdn-base-url
#
# The placeholder ${CDN_BASE_URL} in HTML files is replaced with the resolved
# CloudFront URL so all static assets (images, scripts, stylesheets) are
# loaded from the CDN rather than localhost, enabling proper multi-container
# deployments and Kubernetes service discovery.
# ---------------------------------------------------------------------------
echo "[entrypoint] Injecting CDN_BASE_URL from AWS SSM Parameter Store environment variable..."

CDN_BASE_URL="${CDN_BASE_URL:-}"

echo "[entrypoint]   CDN_BASE_URL = ${CDN_BASE_URL}"

find "${HTML_ROOT}" -type f -name "*.html" | while read -r html_file; do
    if grep -q '\${CDN_BASE_URL}' "${html_file}" 2>/dev/null; then
        echo "[entrypoint] Substituting CDN_BASE_URL in: ${html_file}"
        sed -i "s|\${CDN_BASE_URL}|${CDN_BASE_URL}|g" "${html_file}"
    fi
done

echo "[entrypoint] CDN_BASE_URL substitution complete."

# ---------------------------------------------------------------------------
# Phase 5 (cz-html-1011): window.__ENV__ runtime config injection
#
# The SSM Agent sidecar container writes a config.json to a shared volume
# at /usr/share/nginx/html/config/runtime-config.json, which Nginx serves
# as the runtime config endpoint consumed by the browser.
#
# In addition, the docker-entrypoint.sh substitutes the ${RUNTIME_*}
# placeholders inside the window.__ENV__ script block in HTML files so that
# the browser receives fully-resolved configuration values without an extra
# HTTP round-trip to /config/runtime-config.json.
#
# ECS Task Definition (secrets block):
#   - name: RUNTIME_API_BASE_URL
#     valueFrom: arn:aws:ssm:<REGION>:<ACCOUNT>:parameter/acme/dashboard/api-base-url
#   - name: RUNTIME_APP_ENV
#     valueFrom: arn:aws:ssm:<REGION>:<ACCOUNT>:parameter/acme/dashboard/app-env
#   - name: RUNTIME_FEATURE_FLAGS
#     valueFrom: arn:aws:ssm:<REGION>:<ACCOUNT>:parameter/acme/dashboard/feature-flags
# ---------------------------------------------------------------------------
echo "[entrypoint] Injecting window.__ENV__ runtime config from SSM Parameter Store environment variables..."

RUNTIME_API_BASE_URL="${RUNTIME_API_BASE_URL:-}"
RUNTIME_APP_ENV="${RUNTIME_APP_ENV:-production}"
RUNTIME_FEATURE_FLAGS="${RUNTIME_FEATURE_FLAGS:-{}}"

echo "[entrypoint]   RUNTIME_API_BASE_URL  = ${RUNTIME_API_BASE_URL}"
echo "[entrypoint]   RUNTIME_APP_ENV       = ${RUNTIME_APP_ENV}"
echo "[entrypoint]   RUNTIME_FEATURE_FLAGS = ${RUNTIME_FEATURE_FLAGS}"

find "${HTML_ROOT}" -type f -name "*.html" | while read -r html_file; do
    if grep -q '\${RUNTIME_' "${html_file}" 2>/dev/null; then
        echo "[entrypoint] Substituting window.__ENV__ runtime config in: ${html_file}"
        sed -i "s|\${RUNTIME_API_BASE_URL}|${RUNTIME_API_BASE_URL}|g"   "${html_file}"
        sed -i "s|\${RUNTIME_APP_ENV}|${RUNTIME_APP_ENV}|g"             "${html_file}"
        sed -i "s|\${RUNTIME_FEATURE_FLAGS}|${RUNTIME_FEATURE_FLAGS}|g" "${html_file}"
    fi
done

# Write the SSM-sourced config.json to the shared volume so Nginx can serve
# it at GET /config/runtime-config.json (consumed by the browser as a
# secondary config fetch and by the SSM Agent sidecar health probe).
CONFIG_DIR="${HTML_ROOT}/config"
mkdir -p "${CONFIG_DIR}"
cat > "${CONFIG_DIR}/runtime-config.json" <<EOF
{
  "API_BASE_URL":      "${RUNTIME_API_BASE_URL}",
  "APP_ENV":           "${RUNTIME_APP_ENV}",
  "FEATURE_FLAGS":     "${RUNTIME_FEATURE_FLAGS}",
  "CDN_BASE_URL":      "${CDN_BASE_URL}",
  "ADMIN_CONSOLE_URL": "${ADMIN_CONSOLE_URL}"
}
EOF

echo "[entrypoint] window.__ENV__ runtime config injection complete."

# Execute the main container command (e.g., nginx, java, etc.)
exec "$@"
