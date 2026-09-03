##@ Sample CR helpers

.PHONY: deploy-sample-cr
deploy-sample-cr: ## Deploy sample CUDNBgpConfig and CUDNBgpRouting CRs.
	@echo -e "\n==> Deploy sample CUDNBgpConfig"
	kubectl apply -f ./config/samples/networking_v1alpha1_cudnbgpconfig.yaml
	@echo -e "\n==> Deploy sample CUDNBgpRouting"
	kubectl apply -f ./config/samples/networking_v1alpha1_cudnbgprouting.yaml

.PHONY: undeploy-sample-cr
undeploy-sample-cr: ## Remove sample CRs (routing first, then config, for finalizer cleanup).
	@echo -e "\n==> Undeploy sample CUDNBgpRouting"
	kubectl delete cudnbgprouting cudn1 --ignore-not-found=true
	@echo -e "\n==> Undeploy sample CUDNBgpConfig"
	kubectl delete cudnbgpconfig cluster --ignore-not-found=true
