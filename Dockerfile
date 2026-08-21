# =============================================================================
# Dockerfile — acme-portal-static (HTMLMono2)
# Multi-stage build:
#   Stage 1 (builder): Compile the Java backend JAR with Maven
#   Stage 2 (runtime): nginx serves static HTML; Java backend serves /api/*
# =============================================================================

# ── Stage 1: Build Java backend ───────────────────────────────────────────────
FROM maven:3.9.4-eclipse-temurin-17 AS builder

WORKDIR /workspace

# Copy dependency descriptor first for layer caching
COPY pom.xml .

# Download all dependencies offline (cached layer)
RUN mvn dependency:go-offline -q

# Copy source code and build
COPY src ./src
RUN mvn clean package -DskipTests -q

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM eclipse-temurin:17-jdk

# Install nginx
RUN apt-get update && apt-get install -y --no-install-recommends nginx && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user for the Java backend process
RUN groupadd --system appgroup && useradd --system --gid appgroup --no-create-home appuser

# Copy static HTML assets into the nginx document root
COPY index.html        /usr/share/nginx/html/
COPY pages/            /usr/share/nginx/html/pages/
COPY partials/         /usr/share/nginx/html/partials/
COPY forms/            /usr/share/nginx/html/forms/
COPY app/              /usr/share/nginx/html/app/
COPY assets/           /usr/share/nginx/html/assets/

# Copy the compiled Java backend JAR
COPY --from=builder /workspace/target/acme-portal-static.jar /app/acme-portal-static.jar

# Copy the ENTRYPOINT script
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Nginx configuration: proxy /api/* to the Java backend on port 8081
RUN printf 'server {\n\
    listen 8080;\n\
    root /usr/share/nginx/html;\n\
    index index.html;\n\
\n\
    location /api/ {\n\
        proxy_pass http://127.0.0.1:8081;\n\
        proxy_set_header Host $host;\n\
        proxy_set_header X-Real-IP $remote_addr;\n\
    }\n\
\n\
    location / {\n\
        try_files $uri $uri/ /index.html;\n\
    }\n\
}\n' > /etc/nginx/sites-available/default

# Expose HTTP port
EXPOSE 8080

# HTML_ROOT consumed by docker-entrypoint.sh
ENV HTML_ROOT=/usr/share/nginx/html

# JVM settings
ENV JAVA_OPTS="-Xmx256m -Xms128m -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -Djava.net.preferIPv4Stack=true"

# Timezone
ENV TZ=UTC

# ---------------------------------------------------------------------------
# Runtime configuration environment variables
# These are injected at ECS task startup from AWS SSM Parameter Store /
# Secrets Manager via the ECS task definition secrets block.
# ---------------------------------------------------------------------------
ENV NUXT_PUBLIC_API_BASE=""
ENV NUXT_PUBLIC_APP_TITLE="Acme App"
ENV NUXT_APP_ENV="production"
ENV TELEMETRY_BASE_URL=""
ENV RUNTIME_API_BASE_URL=""
ENV RUNTIME_APP_ENV="production"
ENV RUNTIME_FEATURE_FLAGS="{}"
ENV CDN_BASE_URL=""
ENV ADMIN_CONSOLE_URL=""

# Run path normalization + runtime config substitution, then start nginx + Java
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
