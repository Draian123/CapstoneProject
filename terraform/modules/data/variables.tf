variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. ce-capstone-dev."
  type        = string
}

variable "seed_products" {
  description = "Catalog rows created with the table so a fresh environment has a populated storefront."
  type = list(object({
    id       = string
    name     = string
    category = string
    price    = number
    stock    = number
  }))

  default = [
    { id = "sku-001", name = "Aurora Desk Lamp", category = "Lighting", price = 48.00, stock = 132 },
    { id = "sku-002", name = "Basalt Coffee Table", category = "Furniture", price = 329.00, stock = 14 },
    { id = "sku-003", name = "Cirrus Wall Clock", category = "Decor", price = 62.50, stock = 78 },
    { id = "sku-004", name = "Delta Bookshelf", category = "Furniture", price = 189.00, stock = 23 },
    { id = "sku-005", name = "Ember Floor Rug", category = "Textiles", price = 145.00, stock = 41 },
    { id = "sku-006", name = "Fjord Linen Throw", category = "Textiles", price = 74.00, stock = 96 },
  ]

  validation {
    condition     = length(var.seed_products) > 0
    error_message = "At least one seed product is required so the storefront renders a catalog."
  }
}

variable "enable_point_in_time_recovery" {
  description = "Continuous backup with a 35-day restore window and roughly a 5 minute RPO."
  type        = bool
  default     = true
}

variable "enable_backup_plan" {
  description = "Create the AWS Backup vault, plan and selection covering the catalog table."
  type        = bool
  default     = true
}

variable "backup_schedule" {
  description = "Cron expression for the scheduled backup, in UTC."
  type        = string
  default     = "cron(0 5 * * ? *)"
}

variable "backup_retention_days" {
  description = "How long scheduled recovery points are kept before AWS Backup expires them."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "backup_retention_days must be at least 1."
  }
}

variable "enable_deletion_protection" {
  description = "Block table deletion. Left off in dev so the teardown script can destroy the environment cleanly."
  type        = bool
  default     = false
}
