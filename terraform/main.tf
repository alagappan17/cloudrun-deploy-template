# Infra for one app: Artifact Registry + 2 Cloud Run services + Neon Postgres
# + CI deployer service account + optional custom domains.
#
# Lives in its OWN repo (<app>-infra), separate from the app. Fill
# terraform.tfvars + secrets.tfvars (see *.example), then:
#   terraform init && terraform apply -var-file=secrets.tfvars
#
# Split of responsibility:
#   terraform  → resources, runtime env vars, scaling, domains. Image = placeholder.
#   deploy.yml → builds images and `gcloud run deploy`s them. Never touches env.
# The lifecycle.ignore_changes blocks below are what let both coexist.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    # Delete the neon provider + "Neon" section if the app has no Postgres.
    neon = {
      source  = "kislerdm/neon"
      version = "~> 0.15"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
  # State is local by default: fine for one laptop. Move to GCS before a second
  # machine ever runs apply:
  #   backend "gcs" { bucket = "<project>-tfstate"  prefix = "<app>" }
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

provider "neon" {
  api_key = var.neon_api_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Neon PostgreSQL (free tier, serverless, pgvector available)
# ─────────────────────────────────────────────────────────────────────────────

resource "neon_project" "db" {
  name       = var.app_name
  region_id  = var.neon_region
  pg_version = 16
  org_id     = var.neon_org_id
  # 6h is the free-tier max; larger values fail apply.
  history_retention_seconds = 21600
}

resource "neon_role" "app" {
  project_id = neon_project.db.id
  branch_id  = neon_project.db.default_branch_id
  name       = "${var.app_name}_user"
}

resource "neon_database" "app" {
  project_id = neon_project.db.id
  branch_id  = neon_project.db.default_branch_id
  name       = "${var.app_name}_db"
  owner_name = neon_role.app.name
}

locals {
  database_url = "postgresql://${neon_role.app.name}:${neon_role.app.password}@${neon_project.db.database_host}/${neon_database.app.name}?sslmode=require"
}

# ─────────────────────────────────────────────────────────────────────────────
# GCP APIs
# ─────────────────────────────────────────────────────────────────────────────

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Artifact Registry — deploy.yml pushes to <region>-docker.pkg.dev/<project>/<app_name>
# ─────────────────────────────────────────────────────────────────────────────

resource "google_artifact_registry_repository" "images" {
  location      = var.gcp_region
  repository_id = var.app_name
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# ─────────────────────────────────────────────────────────────────────────────
# CI deployer service account — its JSON key becomes the GCP_SA_KEY secret.
# Key creation is deliberately NOT in terraform (it would sit in plaintext state):
#   gcloud iam service-accounts keys create key.json --iam-account=$(terraform output -raw deployer_email)
# ─────────────────────────────────────────────────────────────────────────────

resource "google_service_account" "deployer" {
  account_id   = "${var.app_name}-deployer"
  display_name = "${var.app_name} GitHub Actions deployer"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "deployer" {
  for_each = toset([
    "roles/run.admin",               # gcloud run deploy
    "roles/artifactregistry.writer", # docker push
    "roles/iam.serviceAccountUser",  # deploy as the Cloud Run runtime SA
  ])
  project = var.gcp_project
  role    = each.key
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Cloud Run: frontend (nginx serving the SPA)
# ─────────────────────────────────────────────────────────────────────────────

resource "google_cloud_run_v2_service" "frontend" {
  name     = "${var.app_name}-frontend"
  location = var.gcp_region

  template {
    containers {
      # Placeholder that answers on 8080 so the service is healthy before CI
      # ever runs. Domain mapping refuses a service with no healthy revision.
      image = "gcr.io/cloudrun/hello"
      ports {
        container_port = 8080
      }
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }
  }

  depends_on = [google_project_service.apis]

  # deploy.yml owns the image and revision; terraform owns everything else.
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].labels,
      template[0].annotations,
      template[0].revision,
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_v2_service_iam_binding" "frontend_public" {
  name     = google_cloud_run_v2_service.frontend.name
  location = google_cloud_run_v2_service.frontend.location
  role     = "roles/run.invoker"
  members  = ["allUsers"]
}

# ─────────────────────────────────────────────────────────────────────────────
# Cloud Run: backend
# ─────────────────────────────────────────────────────────────────────────────

resource "google_cloud_run_v2_service" "backend" {
  name     = "${var.app_name}-backend"
  location = var.gcp_region

  template {
    containers {
      image = "gcr.io/cloudrun/hello"
      ports {
        container_port = 8080
      }
      env {
        name  = "HOST"
        value = "0.0.0.0"
      }
      env {
        name  = "DATABASE_URL"
        value = local.database_url
      }
      env {
        name  = "CORS_ORIGIN"
        value = "https://${var.frontend_domain}"
      }
      # SET: app-specific env. Secrets go through var.backend_secrets so they
      # never appear in this file; plain config can be inlined like above.
      dynamic "env" {
        for_each = var.backend_secrets
        content {
          name  = env.key
          value = env.value
        }
      }
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
  }

  depends_on = [google_project_service.apis]

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].labels,
      template[0].annotations,
      template[0].revision,
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_v2_service_iam_binding" "backend_public" {
  name     = google_cloud_run_v2_service.backend.name
  location = google_cloud_run_v2_service.backend.location
  role     = "roles/run.invoker"
  members  = ["allUsers"]
}

# ─────────────────────────────────────────────────────────────────────────────
# Custom domains. Two-step by design:
#   1. apply with enable_domain_mapping=false (services exist, CI can deploy)
#   2. verify the domain (README §5), flip to true, apply again, add DNS records
#      from `terraform output dns_records`.
# ─────────────────────────────────────────────────────────────────────────────

resource "google_cloud_run_domain_mapping" "frontend" {
  count    = var.enable_domain_mapping ? 1 : 0
  location = var.gcp_region
  name     = var.frontend_domain
  metadata {
    namespace = var.gcp_project
  }
  spec {
    route_name = google_cloud_run_v2_service.frontend.name
  }
}

# Mapping a freshly created service races its first revision; wait it out.
resource "time_sleep" "backend_ready" {
  count           = var.enable_domain_mapping ? 1 : 0
  create_duration = "60s"
  depends_on      = [google_cloud_run_v2_service.backend]
}

resource "google_cloud_run_domain_mapping" "backend" {
  count    = var.enable_domain_mapping ? 1 : 0
  location = var.gcp_region
  name     = var.backend_domain
  metadata {
    namespace = var.gcp_project
  }
  spec {
    route_name = google_cloud_run_v2_service.backend.name
  }
  depends_on = [time_sleep.backend_ready]
}
