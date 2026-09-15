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
# Inference RBAC
#
# Exactly one principal type holds inference permission, decided by
# identity_mode. The two are mutually exclusive by construction, and a
# precondition enforces it: granting humans the role in brokered mode would
# silently reintroduce the direct-backend bypass that mode exists to
# eliminate, while the gateway kept working and nothing would look wrong.
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
resource "terraform_data" "rbac_mode_guard" {
  lifecycle {
    precondition {
      condition     = var.identity_mode == "passthrough" || length(var.inference_principal_ids) == 0
      error_message = <<-EOT
        identity_mode is "brokered" but inference_principal_ids is not empty.

        In brokered mode the gateway's managed identity holds inference RBAC
        and humans hold nothing - that is what removes the direct-backend
        bypass. Granting humans the role as well would restore the bypass
        while everything continued to appear to work.

        Either clear inference_principal_ids, or set
        identity_mode = "passthrough" if you intend end-to-end human identity
        with network-based bypass controls instead.
      EOT
    }
  }
}

# passthrough: the humans who may call the model.
resource "azurerm_role_assignment" "inference_users" {
  for_each = var.identity_mode == "passthrough" ? toset(var.inference_principal_ids) : toset([])

  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = each.value

  depends_on = [terraform_data.rbac_mode_guard]
}

# brokered: the gateway, and only the gateway.
#
# count depends ONLY on identity_mode, which is known at plan time.
#
# An earlier version also tested `broker_principal_id != null` here. That works
# when the gateway already exists, and fails on a FRESH deployment with
# "Invalid count argument" - the principal ID is not known until APIM is
# created. The public deployment masked this because it was converted in
# place; a clean apply of the private profile exposed it.
#
# The null check therefore moves to a precondition, which Terraform is happy
# to defer to apply time.
resource "azurerm_role_assignment" "inference_broker" {
  count = var.identity_mode == "brokered" ? 1 : 0

  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = var.broker_principal_id

  lifecycle {
    precondition {
      condition     = var.broker_principal_id != null
      error_message = "identity_mode is 'brokered' but broker_principal_id is null. The gateway's managed identity must hold inference RBAC, or nothing will be able to call the model."
    }
  }

  depends_on = [terraform_data.rbac_mode_guard]
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
