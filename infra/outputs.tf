# ---------------------------------------------------------------------------
# Outputs
#
# Every value here is non-secret by design.
#
# azd converts Terraform outputs WITHOUT preserving the Sensitive flag, so an
# exported secret would land in the azd environment file in cleartext. The
# rule for this stack is therefore absolute: export identifiers, endpoints,
# and configuration only.
#
# Deliberately absent: Application Insights connection string or
# instrumentation key, any APIM subscription key, any Foundry account key
# (none exists - local auth is disabled), and the jumpbox bootstrap password.
# ---------------------------------------------------------------------------

output "RESOURCE_GROUP_NAME" {
  description = "Resource group containing this deployment."
  value       = azurerm_resource_group.main.name
}

output "DEPLOYMENT_PROFILE" {
  description = "Which pattern was deployed."
  value       = var.deployment_profile
}

output "MAP_GATEWAY_URL" {
  description = "APIM gateway base URL."
  value       = module.gateway.gateway_url
}

output "MAP_RESPONSES_ENDPOINT" {
  description = "Full endpoint the clients call. Set this as MAP_ENDPOINT for the Python CLI and the VS Code extension."
  value       = module.gateway.responses_endpoint
}

output "MAP_MODEL_DEPLOYMENT" {
  description = "The single approved deployment name callers must send as 'model'."
  value       = module.foundry.model_deployment_name
}

output "MAP_TENANT_ID" {
  description = "Tenant whose users may call the gateway. Clients pin their token request to this tenant."
  value       = var.tenant_id
}

output "MAP_API_AUDIENCE" {
  description = "Audience APIM accepts. Clients must request a token whose 'aud' matches this exactly."
  value       = var.api_audience
}

output "FOUNDRY_ACCOUNT_NAME" {
  description = "Azure OpenAI account name, for diagnostics and RBAC verification."
  value       = module.foundry.account_name
}

output "FOUNDRY_DIRECT_ENDPOINT" {
  description = "Direct Foundry endpoint. Exported so the bypass test can attempt it: in the private profile this call MUST fail from the jumpbox even though the caller holds valid inference RBAC."
  value       = module.foundry.endpoint
}

output "APP_INSIGHTS_NAME" {
  description = "Application Insights component name, for running the queries in queries/."
  value       = module.monitoring.app_insights_name
}

output "LOG_ANALYTICS_WORKSPACE_ID" {
  description = "Log Analytics workspace resource ID."
  value       = module.monitoring.workspace_id
}

output "JUMPBOX_NAME" {
  description = "Jumpbox VM name for `az network bastion rdp`. Empty when test access is disabled."
  value       = local.test_access_enabled ? module.test_access[0].jumpbox_name : ""
}

output "BASTION_NAME" {
  description = "Bastion host name. Empty when test access is disabled."
  value       = local.test_access_enabled ? module.test_access[0].bastion_name : ""
}

output "MAP_IDENTITY_MODE" {
  description = "How the gateway authenticates to Foundry. Determines whether a direct-backend bypass is possible, so tooling reads it rather than assuming."
  value       = var.identity_mode
}
