variable "name_suffix" {
  description = "Suffix for test-access resource names."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name."
  type        = string
}

variable "resource_group_id" {
  description = "Resource group resource ID (AzAPI parent_id)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "jumpbox_subnet_id" {
  description = "Subnet for the jumpbox NIC. Denied direct model access by NSG."
  type        = string
}

variable "bastion_subnet_id" {
  description = "AzureBastionSubnet ID."
  type        = string
}

variable "vm_size" {
  description = "Jumpbox size. Must comfortably run VS Code."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "image_sku" {
  description = "Windows image SKU. Entra sign-in requires Windows 10 20H2+, Windows 11 21H2+, or Windows Server 2022+."
  type        = string
  default     = "win11-23h2-pro"
}

variable "admin_username" {
  description = "Local bootstrap account name. Disabled by guest configuration once Entra sign-in is healthy; not an operator credential."
  type        = string
  default     = "mapbootstrap"
}

variable "admin_principal_ids" {
  description = "Entra object IDs granted Virtual Machine User Login plus the Reader assignments the Bastion flow requires."
  type        = list(string)
  default     = []
}

variable "bastion_sku" {
  description = "Bastion SKU. Standard is the minimum for native-client connections."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.bastion_sku)
    error_message = "bastion_sku must be Basic, Standard, or Premium. Developer SKU does not support Entra authentication."
  }
}

variable "acknowledge_unresolved_g4" {
  description = "Explicit acknowledgement that Windows jumpbox access cannot currently satisfy GA-only, passwordless, and no-secret-in-state simultaneously. Must be set deliberately; see docs/deployment.md. Never default this to true."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
