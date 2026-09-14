terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.5" }
    azapi   = { source = "Azure/azapi", version = "~> 2.7" }
  }
}

# ---------------------------------------------------------------------------
# Log Analytics workspace  --  AzAPI, deliberately
#
# Gate G9: azurerm_log_analytics_workspace calls the shared-keys API during
# read and stores the primary and secondary keys in Terraform state, and it
# does so regardless of whether local authentication is disabled on the
# workspace. Those are reusable ingestion credentials, so storing them would
# break the "no reusable authentication secret in state" contract.
#
# AzAPI performs no such key read. The response export below is an explicit
# allowlist containing only the customer ID, which is an identifier and not a
# credential.
# ---------------------------------------------------------------------------
resource "azapi_resource" "workspace" {
  type      = "Microsoft.OperationalInsights/workspaces@2023-09-01"
  name      = var.workspace_name
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  body = {
    properties = {
      sku = {
        name = "PerGB2018"
      }
      retentionInDays = var.retention_days
      features = {
        # Shared-key ingestion disabled; APIM ingests through Entra using its
        # managed identity instead.
        disableLocalAuth = true
      }
      publicNetworkAccessForIngestion = "Enabled"
      publicNetworkAccessForQuery     = "Enabled"
    }
  }

  response_export_values = ["properties.customerId"]
}

# ---------------------------------------------------------------------------
# Application Insights  --  AzureRM is acceptable here
#
# AzureRM stores the instrumentation key and connection string in state.
# Microsoft documents the instrumentation key as an identifier, not a security
# token, and the connection string is required for the APIM logger to target
# this component. Under the approved state contract these are classified as
# telemetry identifiers, not reusable authentication secrets.
#
# Local authentication is disabled, so the connection string alone cannot
# ingest: a caller must also present a token from an identity holding
# Monitoring Metrics Publisher.
# ---------------------------------------------------------------------------
resource "azurerm_application_insights" "main" {
  name                = var.app_insights_name
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = azapi_resource.workspace.id
  application_type    = "web"

  # Entra-only ingestion: the connection string alone cannot ingest, because
  # the caller must also hold Monitoring Metrics Publisher.
  local_authentication_enabled = false

  internet_ingestion_enabled = true
  internet_query_enabled     = true
  retention_in_days          = var.retention_days
  sampling_percentage        = 100
  tags                       = var.tags
}
