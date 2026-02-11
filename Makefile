# Minimal makefile for Sphinx documentation
#

# You can set these variables from the command line, and also
# from the environment for the first two.
SPHINXOPTS    ?=
SPHINXBUILD   ?= sphinx-build
SOURCEDIR     = docs
BUILDDIR      = build

# Terraform helpers
TF_BASE_DIR      ?= base-infrastructure-terraform
TF_PIPELINE_DIR  ?= pipeline-infrastructure-terraform
ENV              ?= dev
MISSION          ?=
TFVARS           ?= $(MISSION).tfvars
WORKSPACE        ?= $(ENV)-$(MISSION)

define require-mission
	@if [ -z "$(MISSION)" ]; then echo "MISSION is required (e.g., make tf-plan-pipeline MISSION=padre)"; exit 1; fi
endef

# Put it first so that "make" without argument is like "make help".
help:
	@$(SPHINXBUILD) -M help "$(SOURCEDIR)" "$(BUILDDIR)" $(SPHINXOPTS) $(O)

.PHONY: help Makefile tf-fmt tf-validate-base tf-validate-pipeline tf-init-base tf-plan-base tf-apply-base tf-workspace tf-init-pipeline tf-plan-pipeline tf-apply-pipeline

# Terraform targets
tf-fmt:
	terraform fmt -recursive

tf-validate-base:
	@cd "$(TF_BASE_DIR)" && terraform init -backend=false && terraform validate

tf-validate-pipeline:
	@cd "$(TF_PIPELINE_DIR)" && terraform init -backend=false && terraform validate

tf-init-base:
	@cd "$(TF_BASE_DIR)" && terraform init

tf-plan-base:
	@cd "$(TF_BASE_DIR)" && terraform plan

tf-apply-base:
	@cd "$(TF_BASE_DIR)" && terraform apply

tf-workspace:
	$(call require-mission)
	@cd "$(TF_PIPELINE_DIR)" && terraform workspace select "$(WORKSPACE)" || terraform workspace new "$(WORKSPACE)"

tf-init-pipeline:
	$(call require-mission)
	@cd "$(TF_PIPELINE_DIR)" && terraform init -reconfigure
	@cd "$(TF_PIPELINE_DIR)" && terraform workspace select "$(WORKSPACE)" || terraform workspace new "$(WORKSPACE)"

tf-plan-pipeline: tf-init-pipeline
	$(call require-mission)
	@cd "$(TF_PIPELINE_DIR)" && terraform plan -var-file="$(TFVARS)"

tf-apply-pipeline: tf-init-pipeline
	$(call require-mission)
	@cd "$(TF_PIPELINE_DIR)" && terraform apply -var-file="$(TFVARS)"

# Catch-all target: route all unknown targets to Sphinx using the new
# "make mode" option.  $(O) is meant as a shortcut for $(SPHINXOPTS).
%: Makefile
	@$(SPHINXBUILD) -M $@ "$(SOURCEDIR)" "$(BUILDDIR)" $(SPHINXOPTS) $(O)
