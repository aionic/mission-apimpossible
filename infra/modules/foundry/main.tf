terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.5" }
  }
}

# ---------------------------------------------------------------------------
# Azure OpenAI account
#
# kind = "OpenAI" is deliberate. This sample exposes exactly one thing: the
# OpenAI v1 Responses endpoint. It needs no Foundry project, no agent
# infrastructure, and no multi-service account.
#
# local_auth_enabled = false at CREATION does two jobs:
#   1. runtime authentication becomes Entra-only, which is the entire point;
#   2. gate G9 - the AzureRM provider skips its AccountsListKeys call when
#      local auth is disabled, so no account key is ever written to state.
#
# Flipping this to true and back would defeat (2) for the life of that state
# file, because historical state is not retroactively sanitized.
#
# custom_subdomain_name is mandatory for Entra authentication and for private
# endpoint DNS.
# ---------------------------------------------------------------------------
resource "azurerm_cognitive_account" "openai" {
  name                  = var.account_name
  location              = var.location
  resource_group_name   = var.resource_group_name
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = var.account_name

  local_auth_enabled = false

  # Private profile: the endpoint is reachable only through its private
  # endpoint. Combined with the NSG rules in the networking module, this is
  # what makes APIM the governed entry point rather than an optional proxy.
  public_network_access_enabled = var.public_network_access_enabled

  dynamic "network_acls" {
    for_each = var.public_network_access_enabled ? [] : [1]
    content {
      default_action = "Deny"
      bypass         = "None"
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.public_network_access_enabled == false || var.allow_public_network
      error_message = "Public network access on the Foundry account is only permitted in the 'public' deployment profile. In the private profile this must stay disabled; do not enable it to troubleshoot RBAC or DNS."
    }
  }
}

# ---------------------------------------------------------------------------
# Model deployment
#
# Exactly one deployment. Callers cannot choose an arbitrary model because
# there is no other model to choose, and APIM independently rejects any
# `model` value that is not this deployment name.
#
# version_upgrade_option is "NoAutoUpgrade": an unannounced model swap would
# invalidate the validation evidence recorded for this deployment. Upgrades
# are a deliberate, reviewed change.
# ---------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "model" {
  name                 = var.model_deployment_name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = var.model_sku
    capacity = var.model_capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
}

# ---------------------------------------------------------------------------
# Human inference RBAC
#
# "Cognitive Services OpenAI User" is the least-privileged BUILT-IN role that
# includes Microsoft.CognitiveServices/accounts/OpenAI/responses/*. It does
# not permit key retrieval, deployment management, or quota access.
#
# It is nonetheless broader than "POST /responses only": it also covers
# completions, embeddings, images, assistants, and video. That residual scope
# is recorded in docs/security.md. A narrower custom role is a documented
# hardening option, not a default, because it must be proven not to break the
# Responses call path.
#
# Scoped to the account, never the resource group or subscription. Owner and
# Contributor are never assigned for inference.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "inference_users" {
  for_each = toset(var.inference_principal_ids)

  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = each.value
}

# ---------------------------------------------------------------------------
# Diagnostics
#
# Gate G10: `allLogs` is never enabled, and RequestResponse and Trace are
# explicitly excluded because they can carry payload material. A category name
# does not establish that its contents are payload-free, so only Audit and
# AzureOpenAIRequestUsage are enabled, and even those are gated on schema
# review before being treated as safe for broad querying.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "openai" {
  name                       = "diag-openai-metadata-only"
  target_resource_id         = azurerm_cognitive_account.openai.id
  log_analytics_workspace_id = var.workspace_id

  enabled_log {
    category = "Audit"
  }

  enabled_log {
    category = "AzureOpenAIRequestUsage"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
