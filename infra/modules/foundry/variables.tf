variable "account_name" {
  description = "Azure OpenAI account name. Also used as the custom subdomain, which Entra authentication and private DNS both require."
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

variable "public_network_access_enabled" {
  description = "Whether the account accepts public network traffic. False for the private profile."
  type        = bool
}

variable "allow_public_network" {
  description = "Guard flag set only by the public profile. Prevents the private profile from silently enabling public access to work around an RBAC or DNS problem."
  type        = bool
  default     = false
}

variable "model_name" {
  description = "Model name, e.g. a current GA coding model."
  type        = string
}

variable "model_version" {
  description = "Exact pinned model version."
  type        = string
}

variable "model_deployment_name" {
  description = "Deployment name. This is the single value APIM accepts in the request 'model' field."
  type        = string
}

variable "model_sku" {
  description = "Deployment SKU, e.g. GlobalStandard or DataZoneStandard."
  type        = string
}

variable "model_capacity" {
  description = "Capacity units."
  type        = number
}

variable "identity_mode" {
  description = "'brokered' (gateway MI holds inference RBAC) or 'passthrough' (humans do)."
  type        = string

  validation {
    condition     = contains(["brokered", "passthrough"], var.identity_mode)
    error_message = "identity_mode must be 'brokered' or 'passthrough'."
  }
}

variable "broker_principal_id" {
  description = "APIM managed identity principal ID. Receives inference RBAC in brokered mode. Null in passthrough mode."
  type        = string
  default     = null
}

variable "inference_principal_ids" {
  description = "Entra object IDs receiving Cognitive Services OpenAI User at account scope. Passthrough mode only; must be empty in brokered mode."
  type        = list(string)
  default     = []
}

variable "workspace_id" {
  description = "Log Analytics workspace resource ID for diagnostics."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
