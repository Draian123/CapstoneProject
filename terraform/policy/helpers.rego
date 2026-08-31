# Shared helpers
#
# Common vocabulary for every policy in this package.
#
# Policies run against `terraform show -json tfplan`, not against the HCL
# source. That matters: the plan is what Terraform will actually do, with
# variables resolved, modules expanded and provider default_tags merged in.
# A policy written against HCL can be defeated by a variable; a policy
# written against the plan cannot.
package main

import rego.v1

# Resources this plan will create or modify.
#
# Deletions and no-ops are excluded. A policy that fires on a resource being
# destroyed would block the teardown of infrastructure that is already
# non-compliant, which is exactly backwards.
changed_resources contains resource if {
	some resource in input.resource_changes
	some action in resource.change.actions
	action in {"create", "update"}
}

# The planned attributes of a changed resource.
resource_after(resource) := resource.change.after

# Terraform reports values it cannot know until apply under `after_unknown`
# rather than `after`. Policies must not fail a resource merely because an
# attribute is computed, so this distinguishes "absent" from "not yet known".
is_unknown(resource, key) if {
	resource.change.after_unknown[key] == true
}

# Effective tags, after provider default_tags have been merged.
#
# `tags_all` is the merged result and `tags` is only what was written inline,
# so checking `tags` would report violations for resources that are correctly
# tagged by the provider block.
effective_tags(resource) := tags if {
	tags := resource.change.after.tags_all
}

effective_tags(resource) := {} if {
	not resource.change.after.tags_all
}
