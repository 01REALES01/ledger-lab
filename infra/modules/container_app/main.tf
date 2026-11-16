terraform {
  required_version = ">= 1.11"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

locals {
  # Azure for Students admite un solo ambiente de Container Apps (no Express) por suscripcion.
  # Si se recibe environment_id, la app se crea en ese ambiente y este modulo no crea uno propio.
  create_environment = var.environment_id == null || var.environment_id == ""
  environment_id     = local.create_environment ? azurerm_container_app_environment.this[0].id : var.environment_id
}

resource "azurerm_log_analytics_workspace" "this" {
  # Los logs se configuran en el ambiente: solo existen si este modulo lo crea.
  count = var.logs_enabled && local.create_environment ? 1 : 0

  name                = "log-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.1 # Tope duro: al llegar aqui se dejan de ingerir logs hasta el dia siguiente.
  tags                = var.tags
}

resource "azurerm_container_app_environment" "this" {
  count = local.create_environment ? 1 : 0

  name                       = "cae-${var.name}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  logs_destination           = length(azurerm_log_analytics_workspace.this) > 0 ? "log-analytics" : null
  log_analytics_workspace_id = length(azurerm_log_analytics_workspace.this) > 0 ? azurerm_log_analytics_workspace.this[0].id : null
  tags                       = var.tags

  # Azure lo agrega siempre; declararlo evita un cambio perpetuo en cada plan. No tiene cargo fijo.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# Desde 2026 Azure crea el ambiente en modo Express si la peticion no indica un modo, y azurerm
# no expone environmentMode. Express no admite secretos referenciados a Key Vault
# (ExpressKeyVaultSecretsNotSupported), asi que se pasa a WorkloadProfiles antes de crear la app.
resource "azapi_resource_action" "workload_profiles_mode" {
  count = local.create_environment ? 1 : 0

  type        = "Microsoft.App/managedEnvironments@2026-07-01"
  resource_id = azurerm_container_app_environment.this[0].id
  method      = "PATCH"
  body = {
    properties = {
      environmentMode = "WorkloadProfiles"
    }
  }
}

# Identidad asignada por el usuario: existe, y tiene permisos, antes de crear la app.
# Con una identidad del sistema la primera revision fallaria al leer los secretos.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "secrets_reader" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}

resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.secrets_reader]
  create_duration = var.rbac_propagation_wait
}

resource "azurerm_container_app" "this" {
  name                         = "ca-${var.name}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = local.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags
  depends_on                   = [time_sleep.rbac_propagation, azapi_resource_action.workload_profiles_mode]

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  dynamic "secret" {
    for_each = var.secret_ids
    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = azurerm_user_assigned_identity.app.id
    }
  }

  ingress {
    external_enabled           = true
    target_port                = 8000
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    http_scale_rule {
      name                = "http"
      concurrent_requests = "20"
    }

    container {
      name   = "ledger"
      image  = var.image
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = var.environment_variables
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }

      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/healthz"
      }

      # Tolera el arranque en frio: reanudar la base en pausa puede tomar cerca de un minuto.
      startup_probe {
        transport               = "HTTP"
        port                    = 8000
        path                    = "/healthz"
        interval_seconds        = 10
        failure_count_threshold = 12
      }
    }
  }
}
