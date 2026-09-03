# cloudrun-deploy-template

Reference for deploying a **Node backend + Vite SPA** to **Google Cloud Run** with
**Docker + GitHub Actions**, infra in **Terraform**, Postgres on **Neon**.
Distilled from a working deployment (mem-soda, Sep 2026). Read this file first
when setting up a new app; every file under it is annotated with `SET:` on the
lines that change per app.

```
.github/workflows/deploy.yml   → copy into the APP repo
docker/backend.Dockerfile      → copy to apps/<backend>/Dockerfile
docker/frontend.Dockerfile     → copy to apps/<frontend>/Dockerfile
docker/nginx.conf.template     → copy next to the frontend Dockerfile
terraform/                     → becomes its own <app>-infra repo
```

## How the pieces split

| Owns                                        | Terraform | deploy.yml |
| ------------------------------------------- | :-------: | :--------: |
| Cloud Run services, scaling, IAM, domains   |     ✓     |            |
| Runtime env vars (DATABASE_URL, secrets)    |     ✓     |            |
| Artifact Registry, deployer service account |     ✓     |            |
| Building images, `gcloud run deploy`        |           |     ✓      |
| Build-time frontend config (`VITE_*`)       |           |     ✓      |

Terraform sets `lifecycle.ignore_changes` on image/revision so both can run
without fighting. **Do not** put env vars in deploy.yml except via
`--update-env-vars` for values that must change per deploy.

## Setup order (do not reorder — later steps need earlier outputs)

### 1. App repo: Dockerfiles

- Copy both Dockerfiles + nginx template. Fill every `SET:`.
- Build context is the repo root. Every workspace `package.json` must be COPYed
  before `npm ci` or the lockfile check fails.
- Backend must read `HOST` and `PORT` from env and listen on `0.0.0.0:8080`.
- Test locally before CI:
  ```bash
  docker build -f apps/backend/Dockerfile -t b . && docker run --rm -p 8080:8080 b
  docker build -f apps/frontend/Dockerfile --build-arg VITE_API_URL=http://localhost:8080 -t f . && docker run --rm -p 8081:8080 f
  ```

### 2. Infra repo: first apply

```bash
mkdir <app>-infra && cp -r terraform/. <app>-infra/ && cd <app>-infra
cp terraform.tfvars.example terraform.tfvars   # fill
cp secrets.tfvars.example secrets.tfvars       # fill (gitignored)
terraform init
terraform apply -var-file=secrets.tfvars       # enable_domain_mapping = false
```

Values you need before this step:

| Value              | Where                                                              |
| ------------------ | ------------------------------------------------------------------ |
| `gcp_project`      | `gcloud projects list` — the ID, not the name                      |
| `neon_api_key`     | https://console.neon.tech/app/settings/api-keys                    |
| `neon_org_id`      | https://console.neon.tech/app/settings → `org-…`                   |
| `backend_secrets`  | whatever the backend reads from env (LLM keys, admin creds, etc.)  |

Postgres extensions (pgvector etc.): Neon has them preinstalled; the app runs
`CREATE EXTENSION IF NOT EXISTS vector` in its migration. Nothing in terraform.

### 3. Deployer key → GitHub secrets

```bash
gcloud iam service-accounts keys create key.json \
  --iam-account=$(terraform output -raw deployer_email)
gh secret set GCP_SA_KEY     --repo <owner>/<app> < key.json && rm key.json
gh secret set GCP_PROJECT_ID --repo <owner>/<app> --body "<gcp_project>"
gh secret set GCP_REGION     --repo <owner>/<app> --body "<gcp_region>"
```

### 4. App repo: workflow

- Copy `deploy.yml`. Fill every `SET:` using `terraform output`:
  `REGISTRY` ← `artifact_registry`, service names ← `cloud_run_*_service_name`,
  `VITE_API_URL` ← `https://<backend_domain>`.
- Push to main or `gh workflow run Deploy`. First run is cold (~4-5 min per
  app); warm cache runs are ~20-30% faster.
- Check: `curl $(terraform output -raw backend_url)/health` (or whatever the
  backend exposes).

### 5. Custom domains (after step 4 succeeded)

1. Verify the **root domain** at https://www.google.com/webmasters/verification
   as the same Google account that runs terraform. Subdomains inherit.
2. `enable_domain_mapping = true` → `terraform apply -var-file=secrets.tfvars`.
3. `terraform output dns_records` → add CNAME/A records at the DNS provider.
4. Cert issues in 15-60 min. Until then `curl` shows `SSL_ERROR_SYSCALL`; that
   is normal, not a deploy failure.

## Gotchas (each one cost real time)

- **Domain mapping needs a healthy revision.** That's why the placeholder
  image is `gcr.io/cloudrun/hello` and mapping is a second apply.
- **A workflow file that fails at parse time shows as a "ghost" run** with no
  jobs and instant completion. `actionlint` the file locally. `matrix.*` is not
  valid inside a job-level `if`; use per-app jobs instead.
- **CORS**: backend `CORS_ORIGIN` must be the frontend's final `https://` domain.
  Terraform derives it from `frontend_domain`, so that's one place to change.
- **Vite bakes `VITE_*` at build time.** Changing the API URL means a rebuild,
  not a redeploy. The `ARG` sits after `COPY . .` so it never busts the install layer.
- **Scoped `npm ci`** (`--workspace` flags) shrinks the build layer ~35% for the
  backend; the frontend gains little because Vite/React pull most of the tree anyway.
- **Local terraform state** is fine solo. Second machine or CI-driven apply →
  GCS backend first (commented stanza in `main.tf`).
- No `setup-gcloud` step: gcloud is preinstalled on `ubuntu-latest`. Adding it
  back costs ~20s per job for nothing.

## Not included (add only when needed)

- Cloud SQL — Neon free tier covers small apps; swap the "Neon" section for
  `google_sql_database_instance` if you outgrow it.
- Secret Manager — secrets are plain Cloud Run env vars set by terraform. Fine
  for one operator; move to `secret_key_ref` when more people can read the console.
- Workload Identity Federation — a SA JSON key is simpler for a solo dev. Switch
  when the key rotation policy matters.
- Preview environments per PR, staging — none. main = prod.
