# Non-secret values → terraform.tfvars. Secrets → secrets.tfvars (gitignored).

variable "app_name" {
  description = "Short slug used for every resource name: <app>-backend, <app>-frontend, registry repo, Neon project, deployer SA. Lowercase, digits, hyphens."
  type        = string
}

variable "gcp_project" {
  description = "GCP project ID (not the display name)."
  type        = string
}

variable "gcp_region" {
  description = "Cloud Run + Artifact Registry region. Must equal the GCP_REGION GitHub secret."
  type        = string
  default     = "asia-southeast1"
}

# --- Domains ---

variable "frontend_domain" {
  description = "e.g. app.example.com. Also becomes the backend's CORS_ORIGIN."
  type        = string
}

variable "backend_domain" {
  description = "e.g. api.example.com. Bake this into the frontend via VITE_API_URL in deploy.yml."
  type        = string
}

variable "enable_domain_mapping" {
  description = "false on first apply. true only after the domain is verified in Google Search Console for the account running terraform."
  type        = bool
  default     = false
}

# --- Neon ---

variable "neon_api_key" {
  description = "https://console.neon.tech/app/settings/api-keys"
  type        = string
  sensitive   = true
}

variable "neon_org_id" {
  description = "org-xxxxxxxx from https://console.neon.tech/app/settings"
  type        = string
}

variable "neon_region" {
  description = "Neon region id. Pick the AWS region closest to gcp_region (aws-ap-southeast-1 pairs with asia-southeast1)."
  type        = string
  default     = "aws-ap-southeast-1"
}

# --- Backend runtime ---

variable "backend_secrets" {
  description = "Extra env vars for the backend, e.g. { GOOGLE_GENERATIVE_AI_API_KEY = \"...\" }. Put the map in secrets.tfvars."
  type        = map(string)
  sensitive   = true
  default     = {}
}
