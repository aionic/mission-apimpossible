# ---------------------------------------------------------------------------
# Deployment target
#
# `location` and every model attribute deliberately have NO default. Gate G11
# in docs/platform-validation.md requires an operator to verify model GA
# status, regional availability, new-deployment eligibility, quota, and
# residency as separate checks. A default here would invite deploying a stale
# or unavailable model. This stack fails closed instead.
# ---------------------------------------------------------------------------

variable "subscription_id" {
  description = "Target Azure subscription ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

variable "location" {
  description = "Azure region. Must support APIM Standard v2, the chosen model, and (for the private profile) both private endpoint types."
  type        = string
}

variable "environment_name" {
  description = "Short environment name used in resource names and as a low-cardinality telemetry dimension."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,16}$", var.environment_name))
    error_message = "environment_name must be 2-17 chars, lowercase alphanumeric or hyphen."
  }
}

variable "deployment_profile" {
  description = "Which pattern to deploy. 'public' exposes APIM and Foundry publicly with Entra enforced. 'private' uses private endpoints and NSG rules that block direct Foundry access."
  type        = string

  validation {
    condition     = contains(["public", "private"], var.deployment_profile)
    error_message = "deployment_profile must be 'public' or 'private'."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

variable "tenant_id" {
  description = "The single Entra tenant whose users may call the gateway. 'common' and 'organizations' are rejected: this is a single-tenant enterprise pattern."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.tenant_id))
    error_message = "tenant_id must be a literal tenant GUID, not 'common' or 'organizations'."
  }
}

variable "api_audience" {
  description = "The exact 'aud' claim APIM will accept. Gate G1: this must be the audience OBSERVED in a real token for the configured scope, not a '.default' scope string copied from documentation."
  type        = string
}

variable "allowed_client_app_ids" {
  description = "Entra client application IDs permitted to call the gateway, matched against 'azp' (v2 tokens) or 'appid' (v1 tokens). Gate G2. Typically the VS Code Microsoft auth client and the Azure CLI client. An empty list disables the client allowlist and MUST be justified."
  type        = list(string)
  default     = []
}

variable "inference_principal_ids" {
  description = "Entra object IDs (users or groups) that receive 'Cognitive Services OpenAI User' on the Foundry resource. These are the humans who may call the model. This is NOT automatically the deploying principal."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

variable "model_name" {
  description = "Coding-capable model to deploy, e.g. a current GA gpt-5 family model. No default: verify GA status and regional availability first (gate G11)."
  type        = string
}

variable "model_version" {
  description = "Exact model version. No default: version pinning is required, and pinning is not a guarantee of permanent availability."
  type        = string
}

variable "model_deployment_name" {
  description = "Deployment name callers must send as 'model'. This is the single allowlisted value enforced by APIM policy."
  type        = string
}

variable "model_sku" {
  description = "Deployment SKU, e.g. GlobalStandard or DataZoneStandard. Affects data-processing residency - choose deliberately."
  type        = string
}

variable "model_capacity" {
  description = "Capacity units. Capacity-to-TPM conversion varies by model; do not assume 1 unit equals 1,000 TPM."
  type        = number

  validation {
    condition     = var.model_capacity > 0
    error_message = "model_capacity must be greater than zero."
  }
}

# ---------------------------------------------------------------------------
# Gateway governance
#
# These are operational safeguards, not billing controls. Azure Cost
# Management remains the financial source of truth. Streamed prompt tokens are
# always estimated, and concurrent requests can overshoot (gate G5).
# ---------------------------------------------------------------------------

variable "apim_sku" {
  description = "APIM SKU. Standard v2 is the baseline because it supports both private inbound and outbound VNet integration."
  type        = string
  default     = "StandardV2_1"

  validation {
    condition     = can(regex("^(StandardV2|BasicV2|PremiumV2)_[0-9]+$", var.apim_sku))
    error_message = "apim_sku must be a v2-tier SKU. Classic tiers are not supported by this stack."
  }
}

variable "apim_publisher_name" {
  description = "APIM publisher name (required by the service)."
  type        = string
  default     = "Mission APIMpossible"
}

variable "apim_publisher_email" {
  description = "APIM publisher email (required by the service). Use a team alias, not a personal address."
  type        = string
}

variable "tokens_per_minute" {
  description = "Per-user TPM ceiling, keyed on tid:oid. Returns 429 with Retry-After."
  type        = number
  default     = 20000
}

variable "daily_token_quota" {
  description = "Per-user token quota per fixed UTC calendar day (not a rolling 24h window). Natively returns 403; see docs/api-contract.md."
  type        = number
  default     = 100000
}

variable "max_concurrent_requests_per_user" {
  description = "Concurrent in-flight requests per user."
  type        = number
  default     = 2
}

variable "max_request_bytes" {
  description = "Maximum HTTP request body size. Default 64 KiB sits below every documented APIM ceiling (gate G7)."
  type        = number
  default     = 65536
}

variable "backend_timeout_seconds" {
  description = "Seconds to wait for backend response headers. Coding inference with reasoning can be slow."
  type        = number
  default     = 120
}

variable "normalize_quota_status_to_429" {
  description = "Map daily-quota exhaustion from the native 403 to 429. Leave false until gate G5 proves the quota 403 is reliably distinguishable from an RBAC 403; blanket-remapping 403 would mask genuine authorization failures."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "telemetry_sampling_percentage" {
  description = "APIM diagnostic sampling. 100 proves correlation in reference environments; lower it for production volume."
  type        = number
  default     = 100

  validation {
    condition     = var.telemetry_sampling_percentage > 0 && var.telemetry_sampling_percentage <= 100
    error_message = "telemetry_sampling_percentage must be in (0, 100]."
  }
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Private profile networking
# ---------------------------------------------------------------------------

variable "vnet_address_space" {
  description = "Address space for the private profile VNet. Ignored when deployment_profile is 'public'."
  type        = string
  default     = "10.42.0.0/16"
}

variable "corporate_address_prefixes" {
  description = "Corporate/VPN/ExpressRoute ranges that reach this VNet. Used to build EXPLICIT DENY rules on the Foundry private-endpoint subnet, because a private endpoint alone does not stop an authorized developer (gate G8). Leave empty only when no such connectivity exists."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Optional private test access
# ---------------------------------------------------------------------------

variable "enable_test_access" {
  description = "Provision the Windows jumpbox and Azure Bastion so the private path can be exercised without corporate connectivity. Both are created or neither is. Bastion bills from deployment regardless of use. Ignored when deployment_profile is 'public'."
  type        = bool
  default     = true
}

variable "jumpbox_size" {
  description = "Jumpbox VM size. Needs to comfortably run VS Code."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "jumpbox_admin_principal_ids" {
  description = "Entra object IDs granted 'Virtual Machine User Login' on the jumpbox. Usually the same testers as inference_principal_ids, but kept separate because VM login and model inference are different privileges."
  type        = list(string)
  default     = []
}

variable "bastion_sku" {
  description = "Bastion SKU. Standard is the minimum for native-client connections. See gate G4 - the passwordless story is unresolved."
  type        = string
  default     = "Standard"
}

variable "acknowledge_unresolved_g4" {
  description = "Explicit acknowledgement that Windows jumpbox access cannot currently satisfy GA-only, passwordless, and no-secret-in-state simultaneously. Deployment of the jumpbox fails closed until this is set deliberately. See docs/private-test-access.md. Never default this to true."
  type        = bool
  default     = false
}
