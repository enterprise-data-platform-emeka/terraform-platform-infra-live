.PHONY: plan apply destroy init dev staging prod

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

init:
	@if [ -z "$(filter $(ENVIRONMENTS),$(MAKECMDGOALS))" ]; then \
		echo "Usage: make init <dev|staging|prod>"; \
		exit 1; \
	fi
	@$(call run,$(filter $(ENVIRONMENTS),$(MAKECMDGOALS)),init)