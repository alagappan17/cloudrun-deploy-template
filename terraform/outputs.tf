output "backend_url" {
  description = "Default *.run.app URL — works before any domain mapping."
  value       = google_cloud_run_v2_service.backend.uri
}

output "frontend_url" {
  value = google_cloud_run_v2_service.frontend.uri
}

output "cloud_run_backend_service_name" {
  description = "Paste into deploy.yml: gcloud run deploy <this>"
  value       = google_cloud_run_v2_service.backend.name
}

output "cloud_run_frontend_service_name" {
  value = google_cloud_run_v2_service.frontend.name
}

output "artifact_registry" {
  description = "Paste into deploy.yml env.REGISTRY"
  value       = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project}/${google_artifact_registry_repository.images.repository_id}"
}

output "deployer_email" {
  description = "Create its key with: gcloud iam service-accounts keys create key.json --iam-account=<this>"
  value       = google_service_account.deployer.email
}

output "dns_records" {
  description = "Add these at your DNS provider after enabling domain mapping."
  value = var.enable_domain_mapping ? {
    (var.frontend_domain) = google_cloud_run_domain_mapping.frontend[0].status[0].resource_records
    (var.backend_domain)  = google_cloud_run_domain_mapping.backend[0].status[0].resource_records
  } : {}
}

output "database_url" {
  value     = local.database_url
  sensitive = true
}

output "neon_console" {
  value = "https://console.neon.tech/app/projects/${neon_project.db.id}"
}
