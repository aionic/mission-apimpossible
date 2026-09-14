output "apim_id" {
  description = "API Management resource ID."
  value       = azurerm_api_management.main.id
}

output "apim_name" {
  description = "API Management service name."
  value       = azurerm_api_management.main.name
}

output "gateway_url" {
  description = "Gateway base URL. Clients call <gateway_url>/openai/v1/responses."
  value       = azurerm_api_management.main.gateway_url
}

output "responses_endpoint" {
  description = "Full Responses endpoint the clients target."
  value       = "${azurerm_api_management.main.gateway_url}/openai/v1/responses"
}

output "principal_id" {
  description = "APIM system-assigned identity. Holds Monitoring Metrics Publisher and nothing else - never a Cognitive Services role."
  value       = azurerm_api_management.main.identity[0].principal_id
}

# Deliberately NOT exported: any subscription key. The API requires no
# subscription, the built-in all-access subscription is suspended, and reading
# a key would write it to state.
