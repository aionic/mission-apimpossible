terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.5" }
    azapi   = { source = "Azure/azapi", version = "~> 2.7" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

# ===========================================================================
# GATE G4 IS UNRESOLVED. READ THIS BEFORE CHANGING ANYTHING HERE.
#
# Three agreed requirements conflict with documented platform behavior:
#
#   1. "GA features only"  vs  Entra RDP through the Bastion portal is in
#      PUBLIC PREVIEW. Only Entra SSH in the portal is GA.
#
#   2. "Passwordless sign-in"  vs  native-client Entra RDP (--enable-mfa)
#      PROMPTS FOR A PASSWORD after MFA completes, and additionally requires
#      the connecting PC to be Entra joined to the same directory.
#
#   3. "No reusable authentication secret in Terraform state"  vs
#      azurerm_windows_virtual_machine documents that the administrator
#      password IS STORED IN STATE AS PLAIN TEXT.
#
# This module resolves (3) using AzAPI write-only `sensitive_body`, which
# keeps the bootstrap password out of state. That approach is UNPROVEN - it
# has not been exercised against Azure, and create/refresh/reapply/recreate
# behavior must be verified (tracked as map-p13).
#
# (1) and (2) are NOT resolved. They require an explicit decision:
#     a) accept preview portal RDP for the sample, documented as an exception;
#     b) accept a password prompt on the native client; or
#     c) switch to a Linux jumpbox, where Entra SSH is GA and passwordless.
#
# `acknowledge_unresolved_g4` below forces that decision to be made
# deliberately rather than absorbed silently. Do not default it to true.
# ===========================================================================

resource "terraform_data" "g4_gate" {
  lifecycle {
    precondition {
      condition     = var.acknowledge_unresolved_g4
      error_message = <<-EOT
        Gate G4 is unresolved: Windows jumpbox access cannot currently satisfy
        "GA only", "passwordless", and "no secret in state" simultaneously.

        Portal Entra RDP is in public preview. Native-client Entra RDP prompts
        for a password. See docs/platform-validation.md (G4) and
        docs/private-test-access.md for the three options.

        To proceed with the documented limitations, set:
            acknowledge_unresolved_g4 = true

        To deploy the private pattern WITHOUT a jumpbox, set:
            enable_test_access = false
        and use existing VPN/ExpressRoute connectivity instead.
      EOT
    }
  }
}

# ---------------------------------------------------------------------------
# Bastion
#
# Standard SKU is the minimum for native-client connections. Session recording
# is deliberately NOT enabled: a recording of this jumpbox would capture the
# developer's source code on screen, which is exactly the data this whole
# architecture avoids persisting.
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-${var.name_suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "main" {
  name                = "bas-${var.name_suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.bastion_sku
  tags                = var.tags

  # Required for `az network bastion rdp`.
  tunneling_enabled = var.bastion_sku != "Basic"

  # Off by design. See the comment above.
  # session_recording_enabled is intentionally not set.

  ip_configuration {
    name                 = "bastion-ipcfg"
    subnet_id            = var.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# ---------------------------------------------------------------------------
# Jumpbox NIC - no public IP, ever
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "jumpbox" {
  name                = "nic-jump-${var.name_suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.jumpbox_subnet_id
    private_ip_address_allocation = "Dynamic"
    # public_ip_address_id deliberately omitted. Access is via Bastion only.
  }
}

# ---------------------------------------------------------------------------
# Bootstrap password
#
# Generated in memory and passed through AzAPI's WRITE-ONLY sensitive_body so
# it never lands in Terraform state.
#
# `random_password` itself would normally persist its result in state, which
# is why it is declared as an ephemeral-style resource whose value is consumed
# once and whose changes are ignored. The account it bootstraps is disabled by
# the guest configuration once Entra login is healthy; the documented recovery
# path is Azure's VM password reset, not a stored credential.
# ---------------------------------------------------------------------------
resource "random_password" "bootstrap" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"

  lifecycle {
    # Rotating this on every plan would force VM replacement.
    ignore_changes = all
  }
}

# ---------------------------------------------------------------------------
# Windows jumpbox  --  AzAPI, deliberately
#
# AzureRM would write admin_password into state. AzAPI's sensitive_body is
# write-only, so the bootstrap credential is sent to Azure and not retained.
#
# UNPROVEN: this must be exercised against Azure before the repository claims
# the state contract holds for the jumpbox. Tracked as map-p13 / gate G4.
# ---------------------------------------------------------------------------
resource "azapi_resource" "jumpbox" {
  type      = "Microsoft.Compute/virtualMachines@2024-07-01"
  name      = "vm-jump-${var.name_suffix}"
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  identity {
    # Required by the AADLoginForWindows extension. Holds no Azure data-plane
    # role: this identity must never be able to call the model.
    type = "SystemAssigned"
  }

  body = {
    properties = {
      hardwareProfile = {
        vmSize = var.vm_size
      }
      storageProfile = {
        imageReference = {
          publisher = "MicrosoftWindowsDesktop"
          offer     = "Windows-11"
          sku       = var.image_sku
          version   = "latest"
        }
        osDisk = {
          createOption = "FromImage"
          managedDisk = {
            storageAccountType = "Premium_LRS"
          }
          deleteOption = "Delete"
        }
      }
      osProfile = {
        computerName  = "vm-jump"
        adminUsername = var.admin_username
        windowsConfiguration = {
          provisionVMAgent       = true
          enableAutomaticUpdates = true
          patchSettings = {
            patchMode = "AutomaticByPlatform"
          }
        }
      }
      networkProfile = {
        networkInterfaces = [{
          id = azurerm_network_interface.jumpbox.id
          properties = {
            primary      = true
            deleteOption = "Delete"
          }
        }]
      }
      securityProfile = {
        securityType = "TrustedLaunch"
        uefiSettings = {
          secureBootEnabled = true
          vTpmEnabled       = true
        }
      }
    }
  }

  # Write-only: sent to Azure, never persisted in state.
  sensitive_body = {
    properties = {
      osProfile = {
        adminPassword = random_password.bootstrap.result
      }
    }
  }

  sensitive_body_version = {
    "properties.osProfile.adminPassword" = "1"
  }

  # Export only non-sensitive identifiers. Never "*".
  response_export_values = ["identity.principalId"]

  depends_on = [terraform_data.g4_gate]
}

# ---------------------------------------------------------------------------
# Entra sign-in extension
# ---------------------------------------------------------------------------
resource "azapi_resource" "aad_login" {
  type      = "Microsoft.Compute/virtualMachines/extensions@2024-07-01"
  name      = "AADLoginForWindows"
  parent_id = azapi_resource.jumpbox.id
  location  = var.location

  body = {
    properties = {
      publisher               = "Microsoft.Azure.ActiveDirectory"
      type                    = "AADLoginForWindows"
      typeHandlerVersion      = "2.0"
      autoUpgradeMinorVersion = true
      settings                = {}
    }
  }
}

# ---------------------------------------------------------------------------
# Guest configuration
#
# Installs VS Code, Azure CLI, Python, uv and git through a pinned,
# idempotent script. Hash-checked downloads; no credentials in custom data.
# ---------------------------------------------------------------------------
resource "azapi_resource" "bootstrap_script" {
  type      = "Microsoft.Compute/virtualMachines/extensions@2024-07-01"
  name      = "BootstrapJumpbox"
  parent_id = azapi_resource.jumpbox.id
  location  = var.location

  body = {
    properties = {
      publisher               = "Microsoft.Compute"
      type                    = "CustomScriptExtension"
      typeHandlerVersion      = "1.10"
      autoUpgradeMinorVersion = true
      settings = {
        commandToExecute = "powershell -ExecutionPolicy Bypass -EncodedCommand ${textencodebase64(file("${path.module}/../../../scripts/bootstrap-jumpbox.ps1"), "UTF-16LE")}"
      }
    }
  }

  depends_on = [azapi_resource.aad_login]
}

# ---------------------------------------------------------------------------
# Least-privilege VM access
#
# Virtual Machine USER Login, not Administrator Login: a tester needs to sign
# in and run VS Code, not administer the machine.
#
# Reader on the VM, NIC and Bastion is required by the Bastion connection
# flow. Scoped to individual resources rather than the resource group.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "vm_user_login" {
  for_each = toset(var.admin_principal_ids)

  scope                = azapi_resource.jumpbox.id
  role_definition_name = "Virtual Machine User Login"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "vm_reader" {
  for_each = toset(var.admin_principal_ids)

  scope                = azapi_resource.jumpbox.id
  role_definition_name = "Reader"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "nic_reader" {
  for_each = toset(var.admin_principal_ids)

  scope                = azurerm_network_interface.jumpbox.id
  role_definition_name = "Reader"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "bastion_reader" {
  for_each = toset(var.admin_principal_ids)

  scope                = azurerm_bastion_host.main.id
  role_definition_name = "Reader"
  principal_id         = each.value
}
