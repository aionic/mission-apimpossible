variable "vnet_name" {
  description = "Virtual network name."
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

variable "vnet_address_space" {
  description = "VNet address space. Split into /24 subnets for APIM integration, both private endpoints, the jumpbox, and Bastion."
  type        = string
}

variable "corporate_address_prefixes" {
  description = "Corporate/VPN/ExpressRoute ranges reaching this VNet. Used to ALLOW gateway access and explicitly DENY direct model access. Empty means no such connectivity exists and no rules are created."
  type        = list(string)
  default     = []
}

variable "enable_test_access" {
  description = "Create the jumpbox and Bastion subnets and their NSGs."
  type        = bool
  default     = true
}

variable "openai_account_id" {
  description = "Azure OpenAI account resource ID for its private endpoint."
  type        = string
}

variable "apim_id" {
  description = "API Management resource ID for its gateway private endpoint."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
