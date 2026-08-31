# Cost allocation tagging
#
# Every resource that generates a line on the bill must be attributable to a
# project, an environment and an owner.
#
# This is enforced rather than documented because untagged spend is
# invisible spend: it cannot be filtered in Cost Explorer, it cannot be
# caught by a tag-scoped budget, and it is the reason "who owns this NAT
# Gateway" is an unanswerable question in most AWS accounts.
package main

import rego.v1

# Tags the FinOps model depends on. Project scopes the budget, Environment
# separates dev from prod spend, Owner and CostCenter make the charge
# attributable, ManagedBy distinguishes Terraform-managed resources from
# anything created by hand.
required_tags := {"Project", "Environment", "Owner", "CostCenter", "ManagedBy"}

# Resource types that either cost money directly or are the unit of cost
# attribution for something that does.
#
# Deliberately a positive list rather than "everything taggable". Route table
# associations and IAM policy attachments cost nothing and tagging them adds
# noise without adding accountability.
cost_bearing_types := {
	"aws_instance",
	"aws_nat_gateway",
	"aws_eip",
	"aws_lb",
	"aws_lb_target_group",
	"aws_dynamodb_table",
	"aws_launch_template",
	"aws_cloudwatch_log_group",
	"aws_s3_bucket",
	"aws_vpc",
	"aws_subnet",
	"aws_backup_vault",
}

deny contains msg if {
	some resource in changed_resources
	resource.type in cost_bearing_types

	tags := effective_tags(resource)
	missing := required_tags - {key | some key, _ in tags}
	count(missing) > 0

	msg := sprintf(
		"%s is missing required cost allocation tag(s): %v. Untagged resources cannot be attributed in Cost Explorer or caught by the project budget.",
		[resource.address, concat(", ", sort(missing))],
	)
}

# A tag whose value is empty passes a naive "is the key present" check while
# being just as useless for cost attribution.
deny contains msg if {
	some resource in changed_resources
	resource.type in cost_bearing_types

	tags := effective_tags(resource)
	some key, value in tags
	key in required_tags
	trim_space(value) == ""

	msg := sprintf(
		"%s sets required tag %q to an empty value.",
		[resource.address, key],
	)
}
