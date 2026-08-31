# TFLint configuration.
#
# Complements the other two gates rather than duplicating them: checkov looks
# for security misconfiguration and the OPA policies encode this platform's own
# rules, while TFLint catches Terraform-level mistakes -- an instance type that
# does not exist, a declared variable nobody uses, a deprecated syntax.

config {
  call_module_type = "all"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Naming convention. Everything in this repository uses snake_case resource
# labels; this makes that a rule rather than a habit.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Every input and output carries a description, so `terraform-docs` output and
# the module interfaces stay self-explanatory.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Providers must be version-constrained so a fresh clone resolves the same
# provider a year from now.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}
