output "account_id" {
  description = "Azure OpenAI account resource ID."
  value       = azurerm_cognitive_account.openai.id
}

output "account_name" {
  description = "Azure OpenAI account name."
  value       = azurerm_cognitive_account.openai.name
}

output "endpoint" {
  description = "Account endpoint. The v1 Responses path is <endpoint>openai/v1/responses."
  value       = azurerm_cognitive_account.openai.endpoint
}

output "responses_backend_url" {
  description = "Backend base URL APIM forwards to. No api-version parameter: this is the GA v1 API."
  value       = "${trimsuffix(azurerm_cognitive_account.openai.endpoint, "/")}/openai/v1"
}

output "model_deployment_name" {
  description = "The single allowlisted deployment name."
  value       = azurerm_cognitive_deployment.model.name
}

# Deliberately NOT exported: primary_access_key / secondary_access_key.
# Local authentication is disabled, so no key exists for runtime use. Reading
# one would also reintroduce the state-secret problem this module avoids.
