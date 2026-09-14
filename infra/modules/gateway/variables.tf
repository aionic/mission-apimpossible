variable "apim_name" {
  description = "API Management service name."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "sku_name" {
  description = "APIM SKU, e.g. StandardV2_1."
  type        = string
}

variable "publisher_name" {
  description = "APIM publisher name."
  type        = string
}

variable "publisher_email" {
  description = "APIM publisher email."
  type        = string
}

variable "environment_name" {
  description = "Environment name. Low cardinality; used as a telemetry dimension."
  type        = string
}

# --- Identity policy inputs ------------------------------------------------

variable "tenant_id" {
  description = "The single tenant whose users may call this gateway."
  type        = string
}

variable "api_audience" {
  description = "Exact 'aud' value APIM accepts. Must be the OBSERVED audience, not a scope string (gate G1)."
  type        = string
}

variable "allowed_client_app_ids" {
  description = "Approved client application IDs. Empty disables the check, which is a weaker posture and must be justified."
  type        = list(string)
  default     = []
}

# --- Backend ---------------------------------------------------------------

variable "foundry_backend_url" {
  description = "Azure OpenAI v1 base URL, e.g. https://<account>.openai.azure.com/openai/v1."
  type        = string
}

variable "model_deployment_name" {
  description = "The single deployment name callers may request."
  type        = string
}

# --- Governance ------------------------------------------------------------

variable "tokens_per_minute" {
  description = "Per-user TPM ceiling."
  type        = number
}

variable "daily_token_quota" {
  description = "Per-user tokens per fixed UTC day."
  type        = number
}

variable "max_concurrent_requests_per_user" {
  description = "Concurrent in-flight requests per user."
  type        = number
}

variable "max_request_bytes" {
  description = "Maximum request body size in bytes."
  type        = number
}

variable "backend_timeout_seconds" {
  description = "Backend response-header timeout."
  type        = number
}

# --- Observability ---------------------------------------------------------

variable "app_insights_id" {
  description = "Application Insights resource ID."
  type        = string
}

variable "app_insights_connection_string" {
  description = "Application Insights connection string for the logger. Consumed directly from the monitoring module so it never becomes a root output."
  type        = string
  sensitive   = true
}

variable "workspace_id" {
  description = "Log Analytics workspace resource ID."
  type        = string
}

variable "sampling_percentage" {
  description = "Diagnostic sampling percentage."
  type        = number
}

# --- Networking ------------------------------------------------------------

variable "integration_subnet_id" {
  description = "Delegated subnet for outbound VNet integration. Null for the public profile."
  type        = string
  default     = null
}

variable "disable_public_access" {
  description = "Close public network access after the private endpoint exists. Private profile only."
  type        = bool
  default     = false
}

variable "private_endpoint_dependency" {
  description = "Opaque dependency handle. Forces public-access closure to run only after the private endpoint is established, so the gateway is never unreachable."
  type        = any
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "identity_mode" {
  description = "'brokered' or 'passthrough'. Selects which backend-auth fragment variant is uploaded."
  type        = string

  validation {
    condition     = contains(["brokered", "passthrough"], var.identity_mode)
    error_message = "identity_mode must be 'brokered' or 'passthrough'."
  }
}

variable "backend_mi_resource" {
  description = "Audience for the managed-identity token in brokered mode."
  type        = string
  default     = "https://ai.azure.com"
}
