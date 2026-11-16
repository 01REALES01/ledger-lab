output "url" {
  description = "URL publica HTTPS."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "environment_resources" {
  description = "Ambiente y Log Analytics creados por este modulo (vacio si el ambiente es compartido)."
  value       = concat(azurerm_container_app_environment.this[*].id, azurerm_log_analytics_workspace.this[*].id)
}
