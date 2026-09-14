terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.5" }
  }
}

locals {
  # /16 split into predictable /24s, except AzureBastionSubnet which has its
  # own minimum, and the APIM integration subnet where Microsoft recommends
  # /24 even though /27 is the documented minimum.
  apim_integration_prefix = cidrsubnet(var.vnet_address_space, 8, 0) # x.x.0.0/24
  pe_apim_prefix          = cidrsubnet(var.vnet_address_space, 8, 1) # x.x.1.0/24
  pe_openai_prefix        = cidrsubnet(var.vnet_address_space, 8, 2) # x.x.2.0/24
  jumpbox_prefix          = cidrsubnet(var.vnet_address_space, 8, 3) # x.x.3.0/24
  bastion_prefix          = cidrsubnet(var.vnet_address_space, 8, 4) # x.x.4.0/24
}

resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# APIM outbound integration subnet
#
# Must be dedicated to one APIM instance, delegated to
# Microsoft.Web/serverFarms, and carry an NSG. Minimum /27; /24 recommended.
#
# Important and easy to get wrong: inbound NSG rules on THIS subnet do not
# restrict APIM ingress. Ingress is controlled at the private endpoint. This
# NSG governs what the gateway can reach on its way out.
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "apim_integration" {
  name                 = "snet-apim-integration"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.apim_integration_prefix]

  delegation {
    name = "apim-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_network_security_group" "apim_integration" {
  name                = "nsg-apim-integration"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# The gateway must reach the Foundry private endpoint.
resource "azurerm_network_security_rule" "apim_out_to_openai_pe" {
  name                        = "Allow-Outbound-OpenAI-PE"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.apim_integration.name
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.apim_integration_prefix
  destination_address_prefix  = local.pe_openai_prefix
}

# Documented APIM outbound dependency. Removing this breaks the service even
# though this architecture stores nothing in Key Vault.
resource "azurerm_network_security_rule" "apim_out_keyvault" {
  name                        = "Allow-Outbound-AzureKeyVault"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.apim_integration.name
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "AzureKeyVault"
}

resource "azurerm_network_security_rule" "apim_out_monitor" {
  name                        = "Allow-Outbound-AzureMonitor"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.apim_integration.name
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "AzureMonitor"
}

resource "azurerm_network_security_rule" "apim_out_storage" {
  name                        = "Allow-Outbound-Storage"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.apim_integration.name
  priority                    = 130
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "Storage"
}

resource "azurerm_subnet_network_security_group_association" "apim_integration" {
  subnet_id                 = azurerm_subnet.apim_integration.id
  network_security_group_id = azurerm_network_security_group.apim_integration.id
}

# ---------------------------------------------------------------------------
# APIM inbound private endpoint subnet
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "pe_apim" {
  name                              = "snet-pe-apim"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [local.pe_apim_prefix]
  private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
}

resource "azurerm_network_security_group" "pe_apim" {
  name                = "nsg-pe-apim"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# The jumpbox is SUPPOSED to reach the gateway - that is the whole point.
resource "azurerm_network_security_rule" "pe_apim_allow_jumpbox" {
  name                        = "Allow-Jumpbox-To-Gateway"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe_apim.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.jumpbox_prefix
  destination_address_prefix  = local.pe_apim_prefix
}

resource "azurerm_network_security_rule" "pe_apim_allow_corporate" {
  count = length(var.corporate_address_prefixes) > 0 ? 1 : 0

  name                        = "Allow-Corporate-To-Gateway"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe_apim.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefixes     = var.corporate_address_prefixes
  destination_address_prefix  = local.pe_apim_prefix
}

resource "azurerm_network_security_rule" "pe_apim_deny_rest" {
  name                        = "Deny-Other-Inbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe_apim.name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "pe_apim" {
  subnet_id                 = azurerm_subnet.pe_apim.id
  network_security_group_id = azurerm_network_security_group.pe_apim.id
}

# ---------------------------------------------------------------------------
# Foundry private endpoint subnet  --  THE ANTI-BYPASS CONTROL
#
# This is the most important block in the repository.
#
# A private endpoint on its own does NOT stop an authorized developer from
# calling Foundry directly. Private endpoints are reachable from peered VNets,
# VPN, and ExpressRoute, and the default AllowVNetInBound rule permits that
# traffic. The jumpbox user holds Cognitive Services OpenAI User, so RBAC will
# happily authorize them.
#
# private_endpoint_network_policies must be enabled or the NSG below is simply
# not evaluated for private endpoint traffic - the rules would exist and do
# nothing.
#
# Rule order is the control:
#   100  allow  APIM integration subnet          <- the governed path
#   200  deny   jumpbox subnet                   <- valid RBAC, still blocked
#   210  deny   corporate ranges                 <- valid RBAC, still blocked
#   4000 deny   everything else in the VNet      <- beats AllowVNetInBound
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "pe_openai" {
  name                              = "snet-pe-openai"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [local.pe_openai_prefix]
  private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
}

resource "azurerm_network_security_group" "pe_openai" {
  name                = "nsg-pe-openai"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "pe_openai_allow_apim" {
  name                        = "Allow-APIM-Integration-Only"
  description                 = "The single permitted path to the model. All inference must traverse the gateway."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe_openai.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.apim_integration_prefix
  destination_address_prefix  = local.pe_openai_prefix
}

resource "azurerm_network_security_rule" "pe_openai_deny_jumpbox" {
  name                        = "Deny-Jumpbox-Direct-To-Model"
  description                 = "The jumpbox user holds valid inference RBAC. Network denial is what makes APIM the governed entry point rather than an optional proxy."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe_openai.name
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = local.jumpbox_prefix
  destination_address_prefix  = local.pe_openai_prefix
}

resource "azurerm_network_security_rule" "pe_openai_deny_corporate" {
  count = length(var.corporate_address_prefixes) > 0 ? 1 : 0

  name                        = "Deny-Corporate-Direct-To-Model"
  description                 = "Corporate callers reach the model through the gateway or not at all."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe_openai.name
  priority                    = 210
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefixes     = var.corporate_address_prefixes
  destination_address_prefix  = local.pe_openai_prefix
}

resource "azurerm_network_security_rule" "pe_openai_deny_vnet" {
  name                        = "Deny-All-Other-VNet-Traffic"
  description                 = "Overrides the default AllowVNetInBound rule, which would otherwise permit any connected network."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe_openai.name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "pe_openai" {
  subnet_id                 = azurerm_subnet.pe_openai.id
  network_security_group_id = azurerm_network_security_group.pe_openai.id
}

# ---------------------------------------------------------------------------
# Optional jumpbox and Bastion subnets
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "jumpbox" {
  count = var.enable_test_access ? 1 : 0

  name                 = "snet-jump"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.jumpbox_prefix]
}

resource "azurerm_network_security_group" "jumpbox" {
  count = var.enable_test_access ? 1 : 0

  name                = "nsg-jump"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# RDP reaches the jumpbox only via Bastion. There is no public IP and no
# internet-facing RDP.
resource "azurerm_network_security_rule" "jumpbox_allow_bastion_rdp" {
  count = var.enable_test_access ? 1 : 0

  name                        = "Allow-Bastion-RDP"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.jumpbox[0].name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = local.bastion_prefix
  destination_address_prefix  = local.jumpbox_prefix
}

resource "azurerm_network_security_rule" "jumpbox_deny_inbound" {
  count = var.enable_test_access ? 1 : 0

  name                        = "Deny-Other-Inbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.jumpbox[0].name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

# Explicit egress denial to the model, mirroring the ingress rule on the
# Foundry PE subnet. Defence in depth: either rule alone would block the
# bypass, and having both means a mistake in one does not silently open it.
resource "azurerm_network_security_rule" "jumpbox_deny_openai_egress" {
  count = var.enable_test_access ? 1 : 0

  name                        = "Deny-Direct-Model-Egress"
  description                 = "Mirrors the Foundry PE ingress denial so the bypass stays closed if either rule is misconfigured."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.jumpbox[0].name
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = local.jumpbox_prefix
  destination_address_prefix  = local.pe_openai_prefix
}

resource "azurerm_subnet_network_security_group_association" "jumpbox" {
  count = var.enable_test_access ? 1 : 0

  subnet_id                 = azurerm_subnet.jumpbox[0].id
  network_security_group_id = azurerm_network_security_group.jumpbox[0].id
}

# Bastion requires this exact subnet name.
resource "azurerm_subnet" "bastion" {
  count = var.enable_test_access ? 1 : 0

  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.bastion_prefix]
}

# ---------------------------------------------------------------------------
# Private DNS
#
# Resolution only. DNS is NOT a security boundary: a developer can supply the
# hostname and address manually. The NSG rules above are the control.
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "apim" {
  name                = "privatelink.azure-api.net"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "openai" {
  name                = "privatelink.openai.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "apim" {
  name                 = "link-apim"
  private_dns_zone_id  = azurerm_private_dns_zone.apim.id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "openai" {
  name                 = "link-openai"
  private_dns_zone_id  = azurerm_private_dns_zone.openai.id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = var.tags
}

# ---------------------------------------------------------------------------
# Private endpoints
# ---------------------------------------------------------------------------
resource "azurerm_private_endpoint" "openai" {
  name                = "pe-openai"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.pe_openai.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-openai"
    private_connection_resource_id = var.openai_account_id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-openai"
    private_dns_zone_ids = [azurerm_private_dns_zone.openai.id]
  }

  depends_on = [azurerm_subnet_network_security_group_association.pe_openai]
}

resource "azurerm_private_endpoint" "apim" {
  name                = "pe-apim"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.pe_apim.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-apim"
    private_connection_resource_id = var.apim_id
    subresource_names              = ["Gateway"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-apim"
    private_dns_zone_ids = [azurerm_private_dns_zone.apim.id]
  }

  depends_on = [azurerm_subnet_network_security_group_association.pe_apim]
}
