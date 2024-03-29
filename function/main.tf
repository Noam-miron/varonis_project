terraform {
  backend "azurerm" {
    resource_group_name  = "tf-state-rg"
    storage_account_name = "tfstatevarproj"
    container_name       = "tfstate"
    key                  = "function.tfstate"
    use_oidc             = true
  }
}
locals {
  func_src_md5  = substr(md5(join("", [for f in fileset("${path.module}/src", "*"): filemd5("${path.module}/src/${f}")])), 0, 6)
}
data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/FunctionApp-${local.func_src_md5}.zip"
}

resource "random_pet" "rg_name" {
  prefix = var.resource_group_name_prefix
}

resource "azurerm_resource_group" "rg" {
  location = var.resource_group_location
  name     = random_pet.rg_name.id
}

resource "random_string" "storage_account_name" {
  length  = 8
  lower   = true
  numeric = false
  special = false
  upper   = false
}

resource "azurerm_storage_account" "storage_account" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  name = random_string.storage_account_name.result

  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_service_plan" "service_plan" {
  name                = "${var.project}-app-service-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_application_insights" "application_insights" {
  name                = "${var.project}-linux-function-app-insights"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  application_type    = "other"
}

resource "azurerm_log_analytics_workspace" "log_analytics_workspace" {
  name                = "${var.project}-log-analytics-workspace"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_linux_function_app" "function_app" {
  name                = "${var.project}-linux-function-app"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key
  service_plan_id            = azurerm_service_plan.service_plan.id

  https_only                  = true
  functions_extension_version = "~4"
  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"       = "python"
    "AzureWebJobsFeatureFlags"       = "EnableWorkerIndexing"
    application_insights_connection_string = "${azurerm_application_insights.application_insights.connection_string}"
    "APPINSIGHTS_INSTRUMENTATIONKEY" = azurerm_application_insights.application_insights.instrumentation_key
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
    cors {

      allowed_origins = ["*"]
    }
  }
  # zip_deploy_file = data.archive_file.function.output_path
}

resource "azurerm_function_app_function" "function_app_function" {
  name            = "api-function"
  function_app_id = azurerm_linux_function_app.function_app.id
  language        = "Python"
  file {
    name    = "function_app.py"
    content = file("./src/function_app.py")
  }
  config_json = file("./src/function.json")
}
