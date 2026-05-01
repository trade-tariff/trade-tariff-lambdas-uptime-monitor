STAGE ?= development

deploy:
	cd terraform && \
	  terraform init -backend-config=../environments/$(STAGE).backend.hcl && \
	  terraform apply -auto-approve -input=false -var-file=../environments/$(STAGE).tfvars

plan:
	cd terraform && \
	  terraform init -backend-config=../environments/$(STAGE).backend.hcl && \
	  terraform plan -var-file=../environments/$(STAGE).tfvars

deploy-development:
	$(MAKE) deploy STAGE=development

deploy-staging:
	$(MAKE) deploy STAGE=staging

deploy-production:
	$(MAKE) deploy STAGE=production
