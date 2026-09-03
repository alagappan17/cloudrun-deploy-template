# Vite SPA → nginx → Cloud Run. Copy to apps/frontend/Dockerfile.
# Build context is the REPO ROOT (see deploy.yml).

FROM node:22-alpine AS build
WORKDIR /app

# SET: one COPY per workspace package.json (see backend.Dockerfile for why).
COPY package.json package-lock.json ./
COPY apps/backend/package.json apps/backend/
COPY apps/frontend/package.json apps/frontend/
COPY packages/shared/package.json packages/shared/

# SET: this app + workspaces it imports. Single-package repo: `RUN npm ci`.
RUN npm ci --include-workspace-root \
      --workspace @scope/frontend --workspace @scope/shared

COPY . .

# Vite inlines VITE_* at build time, so the API URL is a build arg, not runtime.
# Unset → the app's own localhost fallback applies; no domain baked in.
# Declared AFTER install/COPY: changing it must not invalidate those layers.
ARG VITE_API_URL
ENV VITE_API_URL=$VITE_API_URL
RUN npx nx build @scope/frontend # SET: build command

# ── Runtime ──────────────────────────────────────────────────────────────────
# Unprivileged image: non-root out of the box, no chown/USER dance.
FROM nginxinc/nginx-unprivileged:alpine
COPY --from=build /app/apps/frontend/dist/ /usr/share/nginx/html/ # SET: dist path
# /etc/nginx/templates/*.template → envsubst'd into conf.d/ at startup by the base image.
COPY apps/frontend/nginx.conf.template /etc/nginx/templates/default.conf.template
ENV PORT=8080
EXPOSE 8080
