# Node backend → Cloud Run. Copy to apps/backend/Dockerfile.
# Build context is the REPO ROOT (see deploy.yml), not this directory.
#
# Layer order is the whole point: manifests → install → sources → build.
# A source-only change then reuses the npm ci layer from the GHA cache.

FROM node:22-alpine AS build
WORKDIR /app

# SET: one COPY per workspace package.json. The lockfile references them all,
# so npm ci fails if any is missing, even for workspaces you don't install.
COPY package.json package-lock.json ./
COPY apps/backend/package.json apps/backend/
COPY apps/frontend/package.json apps/frontend/
COPY packages/shared/package.json packages/shared/

# SET: only this app + the workspaces it imports. A monorepo-wide install is
# ~270MB bigger through the build cache for nothing.
# Single-package repo: just `RUN npm ci`.
RUN npm ci --include-workspace-root \
      --workspace @scope/backend --workspace @scope/shared

COPY . .
# SET: your build command. Must produce a self-contained dist with its own
# package.json + lockfile (nx prune / esbuild bundle / tsc + copied manifests).
RUN npx nx run @scope/backend:prune

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM node:22-alpine
WORKDIR /app
# Manifests first, then the rest of dist: code changes don't reinstall deps.
COPY --from=build /app/apps/backend/dist/package.json /app/apps/backend/dist/package-lock.json ./
# SET: delete if your prune step doesn't emit workspace_modules/ (nx-specific).
COPY --from=build /app/apps/backend/dist/workspace_modules/ ./workspace_modules/
RUN npm ci --omit=dev
COPY --from=build /app/apps/backend/dist/ ./

USER node
# Cloud Run injects PORT=8080 and needs 0.0.0.0. App must read both.
ENV HOST=0.0.0.0 PORT=8080
EXPOSE 8080
CMD ["node", "main.js"] # SET: entrypoint
