output "products_table_name" {
  description = "Name of the product catalog table, passed to the application as PRODUCTS_TABLE."
  value       = aws_dynamodb_table.products.name
}

output "products_table_arn" {
  description = "ARN of the product catalog table. Used to scope the instance role to this table only."
  value       = aws_dynamodb_table.products.arn
}

output "seeded_product_count" {
  description = "Number of catalog rows managed by Terraform."
  value       = length(aws_dynamodb_table_item.products)
}

output "backup_vault_name" {
  description = "AWS Backup vault holding scheduled recovery points, or null when the backup plan is disabled."
  value       = var.enable_backup_plan ? aws_backup_vault.this[0].name : null
}

output "backup_plan_arn" {
  description = "ARN of the backup plan, or null when the backup plan is disabled."
  value       = var.enable_backup_plan ? aws_backup_plan.this[0].arn : null
}
