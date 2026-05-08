.PHONY: plan apply destroy destroy-safe init dev staging prod

TF=terraform
ENVIRONMENTS=dev staging prod

# Validate environment exists
$(ENVIRONMENTS):
	@:

# Generic runner
define run
	cd environments/$(1) && $(TF) $(2)
endef

# Core commands
plan:
	@if [ -z "$(filter $(ENVIRONMENTS),$(MAKECMDGOALS))" ]; then \
		echo "Usage: make plan <dev|staging|prod>"; \
		exit 1; \
	fi
	@$(call run,$(filter $(ENVIRONMENTS),$(MAKECMDGOALS)),plan)

apply:
	@if [ -z "$(filter $(ENVIRONMENTS),$(MAKECMDGOALS))" ]; then \
		echo "Usage: make apply <dev|staging|prod>"; \
		exit 1; \
	fi
	@$(call run,$(filter $(ENVIRONMENTS),$(MAKECMDGOALS)),apply)

destroy:
	@if [ -z "$(filter $(ENVIRONMENTS),$(MAKECMDGOALS))" ]; then \
		echo "Usage: make destroy <dev|staging|prod>"; \
		exit 1; \
	fi
	@$(call run,$(filter $(ENVIRONMENTS),$(MAKECMDGOALS)),destroy)

destroy-safe:
	@if [ -z "$(filter $(ENVIRONMENTS),$(MAKECMDGOALS))" ]; then \
		echo "Usage: make destroy-safe <dev|staging|prod>"; \
		exit 1; \
	fi
	@ENV=$(filter $(ENVIRONMENTS),$(MAKECMDGOALS)); \
	cd environments/$$ENV && \
	TARGETS=$$(terraform state list 2>/dev/null | \
		sed 's/\..*//' | sort -u | \
		grep '^module\.' | \
		grep -v '^module\.data_lake$$' | \
		sed 's/^/-target=/' | tr '\n' ' '); \
	if [ -z "$$TARGETS" ]; then \
		echo "No Terraform state found — nothing to destroy."; \
	else \
		terraform destroy $$TARGETS -auto-approve; \
	fi

init:
	@if [ -z "$(filter $(ENVIRONMENTS),$(MAKECMDGOALS))" ]; then \
		echo "Usage: make init <dev|staging|prod>"; \
		exit 1; \
	fi
	@$(call run,$(filter $(ENVIRONMENTS),$(MAKECMDGOALS)),init)