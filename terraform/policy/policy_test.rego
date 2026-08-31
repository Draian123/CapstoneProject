# Policy unit tests
#
# Tests for the policies themselves, run by `conftest verify`.
#
# A policy that never fires is indistinguishable from a policy that passes,
# which is how policy suites quietly rot into decoration. Each rule below is
# tested twice: once with input that must be rejected, and once with input
# that must be allowed, so a rule that stops matching is caught immediately.
package main

import rego.v1

# --- Fixtures ---------------------------------------------------------------

compliant_tags := {
	"Project": "ce-capstone",
	"Environment": "dev",
	"Owner": "dennis-beitel",
	"CostCenter": "ironhack-bootcamp",
	"ManagedBy": "terraform",
}

# Wraps a single planned resource in the shape `terraform show -json` produces.
plan_with(resource_type, address, after) := {"resource_changes": [{
	"address": address,
	"type": resource_type,
	"change": {
		"actions": ["create"],
		"after": after,
		"after_unknown": {},
	},
}]}

# --- Tagging ----------------------------------------------------------------

test_untagged_nat_gateway_is_denied if {
	result := deny with input as plan_with(
		"aws_nat_gateway",
		"module.networking.aws_nat_gateway.this[0]",
		{"tags_all": {"Name": "nat"}},
	)

	count(result) == 1
}

test_fully_tagged_nat_gateway_is_allowed if {
	result := deny with input as plan_with(
		"aws_nat_gateway",
		"module.networking.aws_nat_gateway.this[0]",
		{"tags_all": compliant_tags},
	)

	count(result) == 0
}

test_empty_tag_value_is_denied if {
	result := deny with input as plan_with(
		"aws_dynamodb_table",
		"module.data.aws_dynamodb_table.products",
		{"tags_all": object.union(compliant_tags, {"Owner": "   "})},
	)

	count(result) == 1
}

# Resources that cost nothing are outside the tagging requirement.
test_untagged_route_table_association_is_allowed if {
	result := deny with input as plan_with(
		"aws_route_table_association",
		"module.networking.aws_route_table_association.private[0]",
		{},
	)

	count(result) == 0
}

# --- Network ----------------------------------------------------------------

test_public_ssh_is_denied if {
	result := deny with input as plan_with(
		"aws_vpc_security_group_ingress_rule",
		"aws_vpc_security_group_ingress_rule.ssh",
		{"cidr_ipv4": "0.0.0.0/0", "from_port": 22, "to_port": 22},
	)

	count(result) > 0
}

# A wide port range that happens to contain 22 is the same exposure.
test_public_port_range_covering_ssh_is_denied if {
	result := deny with input as plan_with(
		"aws_vpc_security_group_ingress_rule",
		"aws_vpc_security_group_ingress_rule.wide",
		{"cidr_ipv4": "0.0.0.0/0", "from_port": 1, "to_port": 1024},
	)

	count(result) > 0
}

test_public_http_is_allowed if {
	result := deny with input as plan_with(
		"aws_vpc_security_group_ingress_rule",
		"module.networking.aws_vpc_security_group_ingress_rule.alb_http",
		{"cidr_ipv4": "0.0.0.0/0", "from_port": 80, "to_port": 80},
	)

	count(result) == 0
}

# The application port is reachable only via the ALB security group, never
# from a CIDR, so it must not be flagged.
test_app_port_from_security_group_is_allowed if {
	result := deny with input as plan_with(
		"aws_vpc_security_group_ingress_rule",
		"module.networking.aws_vpc_security_group_ingress_rule.app_from_alb",
		{"referenced_security_group_id": "sg-123", "from_port": 3000, "to_port": 3000},
	)

	count(result) == 0
}

test_public_subnet_auto_assign_ip_is_denied if {
	result := deny with input as plan_with(
		"aws_subnet",
		"module.networking.aws_subnet.public[0]",
		{"map_public_ip_on_launch": true, "tags_all": compliant_tags},
	)

	count(result) == 1
}

test_alb_without_drop_invalid_headers_is_denied if {
	result := deny with input as plan_with(
		"aws_lb",
		"module.compute.aws_lb.this",
		{
			"load_balancer_type": "application",
			"drop_invalid_header_fields": false,
			"tags_all": compliant_tags,
		},
	)

	count(result) == 1
}

# --- Data protection --------------------------------------------------------

test_imdsv1_launch_template_is_denied if {
	result := deny with input as plan_with(
		"aws_launch_template",
		"module.compute.aws_launch_template.app",
		{
			"tags_all": compliant_tags,
			"metadata_options": [{"http_tokens": "optional", "http_put_response_hop_limit": 1}],
		},
	)

	count(result) == 1
}

test_imdsv2_launch_template_is_allowed if {
	result := deny with input as plan_with(
		"aws_launch_template",
		"module.compute.aws_launch_template.app",
		{
			"tags_all": compliant_tags,
			"metadata_options": [{"http_tokens": "required", "http_put_response_hop_limit": 1}],
		},
	)

	count(result) == 0
}

test_imds_hop_limit_above_one_is_denied if {
	result := deny with input as plan_with(
		"aws_launch_template",
		"module.compute.aws_launch_template.app",
		{
			"tags_all": compliant_tags,
			"metadata_options": [{"http_tokens": "required", "http_put_response_hop_limit": 2}],
		},
	)

	count(result) == 1
}

test_log_group_without_retention_is_denied if {
	result := deny with input as plan_with(
		"aws_cloudwatch_log_group",
		"module.compute.aws_cloudwatch_log_group.app",
		{"tags_all": compliant_tags},
	)

	count(result) == 1
}

test_log_group_with_retention_is_allowed if {
	result := deny with input as plan_with(
		"aws_cloudwatch_log_group",
		"module.compute.aws_cloudwatch_log_group.app",
		{"tags_all": compliant_tags, "retention_in_days": 7},
	)

	count(result) == 0
}

test_dynamodb_without_pitr_is_denied if {
	result := deny with input as plan_with(
		"aws_dynamodb_table",
		"module.data.aws_dynamodb_table.products",
		{"tags_all": compliant_tags, "point_in_time_recovery": [{"enabled": false}]},
	)

	count(result) == 1
}

# --- IAM --------------------------------------------------------------------

test_administrator_access_attachment_is_denied if {
	result := deny with input as plan_with(
		"aws_iam_role_policy_attachment",
		"aws_iam_role_policy_attachment.too_much",
		{"policy_arn": "arn:aws:iam::aws:policy/AdministratorAccess"},
	)

	count(result) == 1
}

test_scoped_managed_policy_attachment_is_allowed if {
	result := deny with input as plan_with(
		"aws_iam_role_policy_attachment",
		"module.compute.aws_iam_role_policy_attachment.ssm_core",
		{"policy_arn": "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"},
	)

	count(result) == 0
}

test_wildcard_policy_is_denied if {
	result := deny with input as plan_with(
		"aws_iam_policy",
		"aws_iam_policy.wildcard",
		{"policy": json.marshal({"Statement": [{
			"Effect": "Allow",
			"Action": "*",
			"Resource": "*",
		}]})},
	)

	count(result) == 1
}

test_scoped_policy_is_allowed if {
	result := deny with input as plan_with(
		"aws_iam_policy",
		"module.compute.aws_iam_policy.catalog_read",
		{"policy": json.marshal({"Statement": [{
			"Effect": "Allow",
			"Action": ["dynamodb:GetItem", "dynamodb:Scan"],
			"Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/products",
		}]})},
	)

	count(result) == 0
}

test_iam_access_key_is_denied if {
	result := deny with input as plan_with(
		"aws_iam_access_key",
		"aws_iam_access_key.deploy",
		{"user": "deploy"},
	)

	count(result) == 1
}

# --- Availability -----------------------------------------------------------

test_asg_below_minimum_size_is_denied if {
	result := deny with input as plan_with(
		"aws_autoscaling_group",
		"module.compute.aws_autoscaling_group.app",
		{
			"min_size": 1,
			"vpc_zone_identifier": ["subnet-a", "subnet-b"],
			"health_check_type": "ELB",
		},
	)

	count(result) == 1
}

test_asg_in_single_az_is_denied if {
	result := deny with input as plan_with(
		"aws_autoscaling_group",
		"module.compute.aws_autoscaling_group.app",
		{
			"min_size": 3,
			"vpc_zone_identifier": ["subnet-a"],
			"health_check_type": "ELB",
		},
	)

	count(result) == 1
}

test_asg_with_ec2_health_check_is_denied if {
	result := deny with input as plan_with(
		"aws_autoscaling_group",
		"module.compute.aws_autoscaling_group.app",
		{
			"min_size": 3,
			"vpc_zone_identifier": ["subnet-a", "subnet-b"],
			"health_check_type": "EC2",
		},
	)

	count(result) == 1
}

test_compliant_asg_is_allowed if {
	result := deny with input as plan_with(
		"aws_autoscaling_group",
		"module.compute.aws_autoscaling_group.app",
		{
			"min_size": 3,
			"vpc_zone_identifier": ["subnet-a", "subnet-b"],
			"health_check_type": "ELB",
		},
	)

	count(result) == 0
}

# --- Lifecycle --------------------------------------------------------------

# Destroying a non-compliant resource must never be blocked, or the policy
# gate would prevent cleaning up the very thing it objects to.
test_destroying_a_noncompliant_resource_is_allowed if {
	result := deny with input as {"resource_changes": [{
		"address": "aws_iam_access_key.legacy",
		"type": "aws_iam_access_key",
		"change": {
			"actions": ["delete"],
			"after": null,
			"after_unknown": {},
		},
	}]}

	count(result) == 0
}
