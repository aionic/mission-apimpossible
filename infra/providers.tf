terraform {
  # 1.11 is a hard floor, not a preference: AzAPI write-only `sensitive_body`
  # requires it, and that is how bootstrap material is kept out of state.
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.5"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    cognitive_account {
      # Soft-deleted accounts hold the custom subdomain hostage and break
      # redeploys under the same name. Purge so `azd down` is actually clean.
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      # Fail loudly rather than silently orphaning resources this stack did
      # not create.
      prevent_deletion_if_contains_resources = true
    }
  }

  subscription_id = var.subscription_id

  # AzureRM 5.x registers no providers by default. Registering only what this
  # stack needs avoids requiring subscription-wide permissions.
  #
  # Microsoft.Compute is included because the PRIVATE profile's optional
  # jumpbox creates virtual machines and extensions. Omitting it meant
  # jumpbox creation failed mid-apply with MissingSubscriptionRegistration,
  # after Bastion and its public IP had already been billed.
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.ApiManagement",
    "Microsoft.CognitiveServices",
    "Microsoft.Insights",
    "Microsoft.OperationalInsights",
    "Microsoft.Network",
    "Microsoft.Compute",
  ]
}

provider "azapi" {
  subscription_id = var.subscription_id

  # Never let the provider export response bodies wholesale; each AzAPI
  # resource declares an explicit, minimal output allowlist instead.
  enable_preflight = true
}

provider "random" {}
