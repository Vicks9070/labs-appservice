###############################################################################
# Terraform configuration for Datadog log archiving to Azure Blob Storage
# and Datadog log index/archive resources.
#
# This provisions:
#   1. Azure Storage Account + Container for log archives
#   2. Lifecycle policy (Hot -> Cool -> Archive -> Delete)
#   3. Datadog log index with 90-day retention
#   4. Datadog log archive pointing to the Azure Blob container
###############################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.30"
    }
  }
}

# ---------- Variables --------------------------------------------------------

variable "resource_group_name" {
  description = "Azure resource group for the storage account"
  type        = string
  default     = "rg-brezyweather"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "storage_account_name" {
  description = "Name of the Azure Storage Account for log archives"
  type        = string
  default     = "brezyweatherlogsarchive"
}

variable "datadog_api_key" {
  description = "Datadog API key"
  type        = string
  sensitive   = true
}

variable "datadog_app_key" {
  description = "Datadog application key (required for resource management)"
  type        = string
  sensitive   = true
}

variable "datadog_site" {
  description = "Datadog site (e.g., datadoghq.com, datadoghq.eu)"
  type        = string
  default     = "datadoghq.com"
}

variable "log_index_retention_days" {
  description = "Number of days to retain logs in the Datadog index (minimum 90)"
  type        = number
  default     = 90

  validation {
    condition     = var.log_index_retention_days >= 90
    error_message = "Log index retention must be at least 90 days."
  }
}

variable "archive_retention_days" {
  description = "Number of days to retain logs in Azure Blob cold storage"
  type        = number
  default     = 365

  validation {
    condition     = var.archive_retention_days >= 90
    error_message = "Archive retention must be at least 90 days."
  }
}

# ---------- Providers --------------------------------------------------------

provider "azurerm" {
  features {}
}

provider "datadog" {
  api_key  = var.datadog_api_key
  app_key  = var.datadog_app_key
  api_url  = "https://api.${var.datadog_site}"
}

# ---------- Azure Storage Account for Log Archives ---------------------------

resource "azurerm_storage_account" "log_archive" {
  name                     = var.storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = {
    purpose = "datadog-log-archive"
    app     = "brezyweather"
  }
}

resource "azurerm_storage_container" "datadog_archives" {
  name                  = "datadog-log-archives"
  storage_account_name  = azurerm_storage_account.log_archive.name
  container_access_type = "private"
}

# ---------- Lifecycle Policy -------------------------------------------------
# Hot (0-30d) -> Cool (30-90d) -> Archive (90-365d) -> Delete (365d)

resource "azurerm_storage_management_policy" "log_lifecycle" {
  storage_account_id = azurerm_storage_account.log_archive.id

  rule {
    name    = "datadog-log-tiering"
    enabled = true

    filters {
      prefix_match = ["datadog-log-archives/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
        delete_after_days_since_modification_greater_than          = var.archive_retention_days
      }
    }
  }
}

# ---------- SAS Token for Datadog Archive Access -----------------------------

data "azurerm_storage_account_sas" "datadog_archive_sas" {
  connection_string = azurerm_storage_account.log_archive.primary_connection_string
  https_only        = true

  resource_types {
    service   = true
    container = true
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  start  = timestamp()
  expiry = timeadd(timestamp(), "8760h") # 1 year

  permissions {
    read    = true
    write   = true
    delete  = false
    list    = true
    add     = true
    create  = true
    update  = false
    process = false
    tag     = false
    filter  = false
  }
}

# ---------- Datadog Log Index (90-day retention) -----------------------------

resource "datadog_logs_index" "brezyweather_production" {
  name           = "brezyweather-production"
  daily_limit    = 5000000 # 5M events/day safety cap -- adjust as needed
  retention_days = var.log_index_retention_days

  filter {
    query = "service:brezyweather env:production"
  }

  # Exclude health checks from indexing (still archived)
  exclusion_filter {
    name       = "health-checks"
    is_enabled = true

    filter {
      query       = "@http.url:/health*"
      sample_rate = 0.0
    }
  }

  # Exclude static asset requests
  exclusion_filter {
    name       = "static-assets"
    is_enabled = true

    filter {
      query       = "@http.url:/lib/* OR @http.url:*.ico"
      sample_rate = 0.0
    }
  }
}

# ---------- Datadog Log Archive (Azure Blob) ---------------------------------

resource "datadog_logs_archive" "azure_blob" {
  name  = "brezyweather-azure-blob-archive"
  query = "*" # Archive all logs

  azure_archive {
    container    = azurerm_storage_container.datadog_archives.name
    client_id    = "" # Set via Azure AD app registration or use SAS below
    tenant_id    = ""
    account      = azurerm_storage_account.log_archive.name
    storage_type = "blob"
    path         = ""
  }

  include_tags          = true
  rehydration_max_scan_size_in_gb = 100
}

# ---------- Outputs ----------------------------------------------------------

output "storage_account_name" {
  value = azurerm_storage_account.log_archive.name
}

output "storage_container_name" {
  value = azurerm_storage_container.datadog_archives.name
}

output "archive_sas_token" {
  value     = data.azurerm_storage_account_sas.datadog_archive_sas.sas
  sensitive = true
}

output "log_index_name" {
  value = datadog_logs_index.brezyweather_production.name
}
