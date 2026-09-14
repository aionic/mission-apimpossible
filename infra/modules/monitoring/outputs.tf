output "workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = azapi_resource.workspace.id
}

output "workspace_customer_id" {
  description = "Workspace customer ID. An identifier, not a credential - safe to export."
  value       = azapi_resource.workspace.output.properties.customerId
}

output "app_insights_id" {
  description = "Application Insights resource ID."
  value       = azurerm_application_insights.main.id
}

output "app_insights_name" {
  description = "Application Insights component name."
  value       = azurerm_application_insights.main.name
}

# The APIM logger requires the connection string. This is a MODULE output
# consumed by the gateway module; it is deliberately never promoted to a ROOT
# output, because azd converts Terraform outputs without preserving the
# Sensitive flag and it would land in the azd environment file in cleartext.
#
# Local authentication is disabled on the component, so the connection string
# alone cannot ingest: the caller must also hold Monitoring Metrics Publisher.
output "app_insights_connection_string" {
  description = "Connection string for the APIM logger. Module-internal use only - never promote to a root output."
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
}

# Deliberately NOT exported: instrumentation_key. The connection string is
# sufficient for the logger, and exporting both widens the surface for no
# benefit.

