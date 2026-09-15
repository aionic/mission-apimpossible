locals {
  is_private = var.deployment_profile == "private"

  # Test access exists only in the private profile - there is nothing to
  # jump to in the public one.
  test_access_enabled = local.is_private && var.enable_test_access

  suffix = "${var.environment_name}-${random_string.suffix.result}"

  base_tags = merge(
    {
      "azd-env-name"       = var.environment_name
      "deployment-profile" = var.deployment_profile
      "project"            = "mission-apimpossible"
      "managed-by"         = "terraform"
    },
    var.tags
  )
}

# Globally unique names are required for the APIM gateway hostname and the
# Foundry custom subdomain.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "azurerm_resource_group" "main" {
  name     = "rg-map-${local.suffix}"
  location = var.location
  tags     = local.base_tags
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
module "monitoring" {
  source = "./modules/monitoring"

  workspace_name      = "log-map-${local.suffix}"
  app_insights_name   = "appi-map-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  resource_group_id   = azurerm_resource_group.main.id
  location            = var.location
  retention_days      = var.log_retention_days
  tags                = local.base_tags
}

# ---------------------------------------------------------------------------
# Model execution boundary
#
# allow_public_network guards against the private profile silently enabling
# public access to work around an RBAC or DNS problem.
# ---------------------------------------------------------------------------
module "foundry" {
  source = "./modules/foundry"

  account_name        = "oai-map-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  public_network_access_enabled = !local.is_private
  allow_public_network          = !local.is_private

  model_name            = var.model_name
  model_version         = var.model_version
  model_deployment_name = var.model_deployment_name
  model_sku             = var.model_sku
  model_capacity        = var.model_capacity

  # Exactly one of these takes effect, decided by identity_mode.
  #
  # Brokered mode grants the gateway's managed identity and NOTHING to humans,
  # which is what removes the direct-backend bypass by capability. The module
  # enforces the exclusivity with a precondition rather than trusting the
  # caller to keep the two lists consistent.
  identity_mode           = var.identity_mode
  broker_principal_id     = var.identity_mode == "brokered" ? module.gateway.principal_id : null
  inference_principal_ids = var.identity_mode == "passthrough" ? var.inference_principal_ids : []

  workspace_id = module.monitoring.workspace_id
  tags         = local.base_tags
}

# ---------------------------------------------------------------------------
# Private networking
#
# Created before the gateway's public-access closure, and holds the NSG rules
# that actually prevent the direct-Foundry bypass.
# ---------------------------------------------------------------------------
module "networking" {
  count  = local.is_private ? 1 : 0
  source = "./modules/networking"

  vnet_name                  = "vnet-map-${local.suffix}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = var.location
  vnet_address_space         = var.vnet_address_space
  corporate_address_prefixes = var.corporate_address_prefixes
  enable_test_access         = local.test_access_enabled

  openai_account_id = module.foundry.account_id
  apim_id           = module.gateway.apim_id

  tags = local.base_tags
}

# ---------------------------------------------------------------------------
# Policy enforcement boundary
# ---------------------------------------------------------------------------
module "gateway" {
  source = "./modules/gateway"

  apim_name           = "apim-map-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku_name            = var.apim_sku
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  environment_name    = var.environment_name

  tenant_id              = var.tenant_id
  api_audience           = var.api_audience
  allowed_client_app_ids = var.allowed_client_app_ids

  identity_mode       = var.identity_mode
  backend_mi_resource = var.backend_mi_resource
  required_scope      = var.required_scope

  foundry_backend_url   = module.foundry.responses_backend_url
  model_deployment_name = module.foundry.model_deployment_name

  tokens_per_minute                = var.tokens_per_minute
  daily_token_quota                = var.daily_token_quota
  max_concurrent_requests_per_user = var.max_concurrent_requests_per_user
  max_request_bytes                = var.max_request_bytes
  backend_timeout_seconds          = var.backend_timeout_seconds

  app_insights_id                = module.monitoring.app_insights_id
  app_insights_connection_string = module.monitoring.app_insights_connection_string
  workspace_id                   = module.monitoring.workspace_id
  sampling_percentage            = var.telemetry_sampling_percentage

  integration_subnet_id = local.is_private ? module.networking[0].apim_integration_subnet_id : null
  disable_public_access = local.is_private

  # Ordering handle: public access closes only after the gateway's private
  # endpoint exists, so the service is never left unreachable.
  private_endpoint_dependency = local.is_private ? module.networking[0].apim_private_endpoint_id : null

  tags = local.base_tags
}

# ---------------------------------------------------------------------------
# Optional private test access
# ---------------------------------------------------------------------------
module "test_access" {
  count  = local.test_access_enabled ? 1 : 0
  source = "./modules/test-access"

  name_suffix         = local.suffix
  resource_group_name = azurerm_resource_group.main.name
  resource_group_id   = azurerm_resource_group.main.id
  location            = var.location

  jumpbox_subnet_id = module.networking[0].jumpbox_subnet_id
  bastion_subnet_id = module.networking[0].bastion_subnet_id

  vm_size             = var.jumpbox_size
  admin_principal_ids = var.jumpbox_admin_principal_ids
  bastion_sku         = var.bastion_sku

  acknowledge_unresolved_g4 = var.acknowledge_unresolved_g4

  tags = local.base_tags
}

# ---------------------------------------------------------------------------
# Authorisation guard.
#
# In brokered mode the gateway calls the model with its OWN managed identity,
# so whoever the policy admits gets inference. If the audience is a Microsoft
# first-party resource - the Foundry audience, say - Entra issues tokens for it
# to every member and guest of the tenant, and without a scope check that is
# precisely who can use the gateway.
#
# Passthrough mode does not need this: the caller's own token reaches Foundry,
# which performs its own RBAC check.
# ---------------------------------------------------------------------------
resource "terraform_data" "authorization_guard" {
  input = "${var.identity_mode}:${var.required_scope}"

  lifecycle {
    precondition {
      condition = var.identity_mode != "brokered" || trimspace(var.required_scope) != ""
      error_message = join("", [
        "identity_mode is 'brokered' but required_scope is empty. ",
        "In brokered mode the gateway calls the model with its managed identity, ",
        "so anyone the policy admits gets inference. With a first-party audience ",
        "that is the entire tenant. Register a dedicated Entra application with ",
        "'user assignment required', expose a scope, and set both api_audience ",
        "and required_scope - or use identity_mode = \"passthrough\", where Foundry ",
        "performs its own authorization check."
      ])
    }
  }
}
