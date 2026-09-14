output "vnet_id" {
  description = "Virtual network resource ID."
  value       = azurerm_virtual_network.main.id
}

output "apim_integration_subnet_id" {
  description = "Delegated subnet for APIM outbound VNet integration."
  value       = azurerm_subnet.apim_integration.id
}

output "jumpbox_subnet_id" {
  description = "Jumpbox subnet ID, or null when test access is disabled."
  value       = var.enable_test_access ? azurerm_subnet.jumpbox[0].id : null
}

output "bastion_subnet_id" {
  description = "AzureBastionSubnet ID, or null when test access is disabled."
  value       = var.enable_test_access ? azurerm_subnet.bastion[0].id : null
}

output "openai_private_endpoint_id" {
  description = "Foundry private endpoint ID. Used as the ordering handle that gates APIM public-access closure."
  value       = azurerm_private_endpoint.openai.id
}

output "apim_private_endpoint_id" {
  description = "APIM gateway private endpoint ID."
  value       = azurerm_private_endpoint.apim.id
}

output "apim_private_ip" {
  description = "Private IP of the APIM gateway endpoint. Useful for diagnosing DNS resolution."
  value       = azurerm_private_endpoint.apim.private_service_connection[0].private_ip_address
}
