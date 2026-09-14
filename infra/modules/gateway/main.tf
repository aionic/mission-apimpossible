terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.5" }
    azapi   = { source = "Azure/azapi", version = "~> 2.7" }
  }
}

locals {
  # Named values injected into policy. None of these are secrets - they are
  # configuration. Anything secret would be a design error here, because the
  # architecture has no runtime secrets.
  named_values = {
    "map-tenant-id"               = var.tenant_id
    "map-api-audience"            = var.api_audience
    "map-allowed-client-app-ids"  = join(",", var.allowed_client_app_ids)
    "map-approved-deployment"     = var.model_deployment_name
    "map-environment-name"        = var.environment_name
    "map-tokens-per-minute"       = tostring(var.tokens_per_minute)
    "map-daily-token-quota"       = tostring(var.daily_token_quota)
    "map-max-concurrent-per-user" = tostring(var.max_concurrent_requests_per_user)
    "map-max-request-bytes"       = tostring(var.max_request_bytes)
    "map-backend-timeout-seconds" = tostring(var.backend_timeout_seconds)
  }

  fragments = {
    "map-correlation"        = "${path.module}/../../../policies/fragments/correlation.xml"
    "map-security-headers"   = "${path.module}/../../../policies/fragments/security-headers.xml"
    "map-authentication"     = "${path.module}/../../../policies/fragments/authentication.xml"
    "map-request-validation" = "${path.module}/../../../policies/fragments/request-validation.xml"
    "map-token-governance"   = "${path.module}/../../../policies/fragments/token-governance.xml"
    "map-observability"      = "${path.module}/../../../policies/fragments/observability.xml"
  }
}

# ---------------------------------------------------------------------------
# API Management, Standard v2
#
# Standard v2 is the baseline because it supports inbound private endpoints
# AND outbound VNet integration simultaneously, which is what the private
# pattern needs.
#
# The identity exists ONLY to publish telemetry through Entra. It is never
# granted any Cognitive Services role. If it were, the gateway could become
# the model caller and the entire end-to-end-identity property would collapse.
#
# Deliberately absent: a `security` block. v2 tiers do not support the classic
# cipher-configuration surface, and declaring unsupported knobs produces
# either an error or silent drift. Unsupported controls are documented in
# docs/security.md instead.
# ---------------------------------------------------------------------------
resource "azurerm_api_management" "main" {
  name                = var.apim_name
  location            = var.location
  resource_group_name = var.resource_group_name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = var.sku_name

  # Private profile: created public (the service requires it), then closed by
  # the azapi_update_resource below once the private endpoint exists. No
  # usable inference API is attached until after that closure - see
  # docs/architecture.md, "Bootstrap ordering".
  public_network_access_enabled = true

  virtual_network_type = var.integration_subnet_id == null ? "None" : "External"

  dynamic "virtual_network_configuration" {
    for_each = var.integration_subnet_id == null ? [] : [var.integration_subnet_id]
    content {
      subnet_id = virtual_network_configuration.value
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      # Owned by azapi_update_resource.close_public_access in the private
      # profile. Two owners for one property would fight on every apply.
      public_network_access_enabled,
    ]
  }
}

# ---------------------------------------------------------------------------
# Telemetry ingestion identity
#
# Monitoring Metrics Publisher on Application Insights, and nothing else.
# This is the complete set of permissions the gateway identity holds.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "apim_metrics_publisher" {
  scope                = var.app_insights_id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_api_management.main.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Logger: Entra-authenticated, no instrumentation key in the resource
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Logger: Entra-authenticated ingestion
#
# identity_client_id = "SystemAssigned" is REQUIRED, not cosmetic.
#
# Application Insights has local (key-based) authentication DISABLED, which is
# the posture this repository argues for. Without telling the logger to use the
# gateway's managed identity, APIM falls back to connection-string ingestion,
# that ingestion is refused, and every `trace` policy throws - surfacing as a
# blanket HTTP 500 on requests that are otherwise completely valid, with no
# telemetry to diagnose it because the telemetry path is the thing that is
# broken.
#
# Found by deploying. See docs/platform-validation.md.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_logger" "app_insights" {
  name                = "map-appinsights"
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  resource_id         = var.app_insights_id

  application_insights {
    connection_string  = var.app_insights_connection_string
    identity_client_id = "SystemAssigned"
  }

  depends_on = [azurerm_role_assignment.apim_metrics_publisher]
}

# ---------------------------------------------------------------------------
# Named values
# ---------------------------------------------------------------------------
resource "azurerm_api_management_named_value" "config" {
  for_each = local.named_values

  name                = each.key
  display_name        = each.key
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  value               = each.value
  secret              = false
}

# ---------------------------------------------------------------------------
# Request schema  --  SERVICE-level, not API-level
#
# This distinction cost a deployment cycle and is worth stating plainly.
#
# The validate-content reference says schema-id is "the name of an existing
# schema that was added to the API Management INSTANCE". An API-scoped schema
# (azurerm_api_management_api_schema, which lives at /apis/{id}/schemas/{id})
# is NOT resolvable by schema-id - the policy fails to apply with
# "The schema responses-request does not exist", even though the schema is
# plainly visible on the API.
#
# azurerm_api_management_global_schema creates the service-level resource
# (Microsoft.ApiManagement/service/schemas) that schema-id actually resolves.
#
# The committed JSON Schema is uploaded verbatim, so the contract enforced at
# runtime is the same artifact reviewed in the repository. It is wrapped in
# components.schemas so the policy's schema-ref pointer has something to
# select.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_global_schema" "responses_request" {
  schema_id           = "responses-request"
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  type                = "json"
  description         = "Mission APIMpossible allowlisted Responses request."

  value = jsonencode({
    components = {
      schemas = {
        "responses-request" = jsondecode(
          file("${path.module}/../../../specs/responses-request.schema.json")
        )
      }
    }
  })
}

# ---------------------------------------------------------------------------
# Backend
#
# No credentials block. This is the point: the backend is reached with
# whatever Authorization the caller supplied, and the gateway adds nothing.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_backend" "foundry" {
  name                = "map-foundry-responses"
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  protocol            = "http"
  url                 = var.foundry_backend_url
  description         = "Azure OpenAI v1 Responses. Receives the caller's original bearer token; holds no credentials of its own."

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

# ---------------------------------------------------------------------------
# API and the single operation
#
# subscription_required = false: runtime access is Entra-only. A subscription
# key would be a second, weaker credential path around the identity model.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_api" "responses" {
  name                  = "map-responses"
  api_management_name   = azurerm_api_management.main.name
  resource_group_name   = var.resource_group_name
  revision              = "1"
  display_name          = "Mission APIMpossible - Responses"
  path                  = "openai/v1"
  protocols             = ["https"]
  subscription_required = false

  description = "Governed passthrough to the Azure OpenAI v1 Responses API, preserving the caller's Microsoft Entra identity."
}

resource "azurerm_api_management_api_operation" "create_response" {
  operation_id        = "create-response"
  api_name            = azurerm_api_management_api.responses.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Create response"
  method              = "POST"
  url_template        = "/responses"
  description         = "The only operation this gateway exposes."

  # Declaring the request representation is not documentation - it is load
  # bearing. `validate-content` treats any content type absent from the API
  # definition as "unspecified", so without this the policy rejects every
  # request with:
  #   400 "Unspecified content type application/json is not allowed."
  #
  # With it declared, unspecified-content-type-action="prevent" keeps its
  # intended meaning: reject genuinely unexpected content types, and validate
  # JSON bodies against the schema.
  request {
    representation {
      content_type = "application/json"
    }
  }

  response {
    status_code = 200
  }
}

# ---------------------------------------------------------------------------
# Policy fragments and policies
# ---------------------------------------------------------------------------
resource "azurerm_api_management_policy_fragment" "fragments" {
  for_each = local.fragments

  name              = each.key
  api_management_id = azurerm_api_management.main.id
  format            = "rawxml"
  value             = file(each.value)

  depends_on = [azurerm_api_management_named_value.config]
}

resource "azurerm_api_management_policy" "global" {
  api_management_id = azurerm_api_management.main.id
  xml_content       = file("${path.module}/../../../policies/global.xml")

  # global.xml includes the observability fragment (its HTTPS rejection uses
  # return-response, which cancels the pipeline before outbound runs). APIM
  # validates fragment-id at policy-set time, so without this edge Terraform
  # would set the policy concurrently with fragment creation and fail
  # intermittently. It also orders teardown correctly: APIM refuses to delete
  # a fragment that a policy still references.
  depends_on = [azurerm_api_management_policy_fragment.fragments]
}

resource "azurerm_api_management_api_operation_policy" "create_response" {
  api_name            = azurerm_api_management_api.responses.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  operation_id        = azurerm_api_management_api_operation.create_response.operation_id
  xml_content         = file("${path.module}/../../../policies/responses.xml")

  depends_on = [
    azurerm_api_management_policy_fragment.fragments,
    azurerm_api_management_backend.foundry,
    azurerm_api_management_global_schema.responses_request,
  ]
}

# ---------------------------------------------------------------------------
# Diagnostics
#
# Gate G10: zero body bytes on ALL FOUR legs (frontend/backend x
# request/response). Microsoft warns that even request-body diagnostic logging
# can disrupt server-sent events, and body capture is how prompts and model
# output would leak into telemetry.
#
# The header allowlist carries correlation identifiers only. Authorization,
# Cookie, and api-key are absent by construction.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_diagnostic" "app_insights" {
  identifier               = "applicationinsights"
  api_management_name      = azurerm_api_management.main.name
  resource_group_name      = var.resource_group_name
  api_management_logger_id = azurerm_api_management_logger.app_insights.id

  sampling_percentage       = var.sampling_percentage
  always_log_errors         = true
  log_client_ip             = false
  verbosity                 = "information"
  http_correlation_protocol = "W3C"
  operation_name_format     = "Name"

  frontend_request {
    body_bytes     = 0
    headers_to_log = ["x-correlation-id", "traceparent", "tracestate", "content-type"]
  }

  frontend_response {
    body_bytes     = 0
    headers_to_log = ["x-correlation-id", "x-foundry-request-id", "content-type"]
  }

  backend_request {
    body_bytes     = 0
    headers_to_log = ["x-correlation-id", "traceparent", "content-type"]
  }

  backend_response {
    body_bytes     = 0
    headers_to_log = ["apim-request-id", "content-type"]
  }
}

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "diag-apim-metadata-only"
  target_resource_id         = azurerm_api_management.main.id
  log_analytics_workspace_id = var.workspace_id

  enabled_log {
    category = "GatewayLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ---------------------------------------------------------------------------
# Built-in all-access subscription
#
# Every APIM instance ships with one. It is suspended here.
#
# Two things had to be right, and both were found by deploying:
#
# 1. METHOD. A PUT is rejected with
#      ValidationError: Subscription scope should be one of '/apis',
#      '/apis/{apiId}', '/products/{productId}'
#    because the built-in subscription's scope is the SERVICE ROOT, which is
#    not a writable scope value. PATCH succeeds - it does not revalidate the
#    unchanged scope. Hence azapi_resource_action with method = "PATCH"
#    rather than azapi_update_resource, which only issues PUT.
#
# 2. RESPONSE HANDLING. The API returns primaryKey and secondaryKey in the
#    PATCH response body. response_export_values is therefore pinned to an
#    empty list so no key material is captured into Terraform state - which
#    is the whole reason this is not the AzureRM subscription resource
#    (gate G9).
#
# The API already sets subscription_required = false, so this is defence in
# depth rather than the primary control.
# ---------------------------------------------------------------------------
resource "azapi_resource_action" "disable_builtin_subscription" {
  type        = "Microsoft.ApiManagement/service/subscriptions@2024-05-01"
  resource_id = "${azurerm_api_management.main.id}/subscriptions/master"
  method      = "PATCH"

  body = {
    properties = {
      state = "suspended"
    }
  }

  # Explicitly export nothing. The response carries subscription keys.
  response_export_values = []

  depends_on = [azurerm_api_management.main]
}

# ---------------------------------------------------------------------------
# Close public access (private profile only)
#
# APIM cannot be created with public access already disabled, so this runs
# after the private endpoint exists. Sole owner of the property - the AzureRM
# resource ignores it - so repeated applies cannot reopen access.
#
# Note: destroying an azapi_update_resource does NOT revert its change. That
# is acceptable here because teardown removes the whole service.
# ---------------------------------------------------------------------------
resource "azapi_update_resource" "close_public_access" {
  count = var.disable_public_access ? 1 : 0

  type        = "Microsoft.ApiManagement/service@2024-05-01"
  resource_id = azurerm_api_management.main.id

  body = {
    properties = {
      publicNetworkAccess = "Disabled"
    }
  }

  depends_on = [
    azurerm_api_management_api_operation_policy.create_response,
    var.private_endpoint_dependency,
  ]
}
