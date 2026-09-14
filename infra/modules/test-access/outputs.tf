output "jumpbox_id" {
  description = "Jumpbox VM resource ID."
  value       = azapi_resource.jumpbox.id
}

output "jumpbox_name" {
  description = "Jumpbox VM name, for `az network bastion rdp --target-resource-id`."
  value       = azapi_resource.jumpbox.name
}

output "bastion_name" {
  description = "Bastion host name."
  value       = azurerm_bastion_host.main.name
}

output "jumpbox_private_ip" {
  description = "Jumpbox private IP. There is no public IP by design."
  value       = azurerm_network_interface.jumpbox.private_ip_address
}

# Deliberately NOT exported: the bootstrap password.
#
# It is passed to Azure through AzAPI's write-only sensitive_body and is never
# persisted. Exporting it would defeat that, and azd converts Terraform
# outputs without preserving the Sensitive flag - it would land in the azd
# environment file in cleartext.
#
# Recovery is through Azure's VM password reset, not a stored credential.
