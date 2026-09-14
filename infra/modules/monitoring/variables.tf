variable "workspace_name" {
  description = "Log Analytics workspace name."
  type        = string
}

variable "app_insights_name" {
  description = "Application Insights component name."
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

variable "retention_days" {
  description = "Retention in days for both the workspace and the component."
  type        = number
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
