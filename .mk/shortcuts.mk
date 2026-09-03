##@ Shortcuts helpers
.PHONY: build-image
build-image: image-build ## Build MULTIARCH_TARGETS images

.PHONY: push-image
push-image: image-push ## Push MULTIARCH_TARGETS images

.PHONY: build-manifest
build-manifest: manifest-build ## Build MULTIARCH_TARGETS manifest

.PHONY: push-manifest
push-manifest: manifest-push ## Push MULTIARCH_TARGETS manifest

.PHONY: images
images: ## Build and push MULTIARCH_TARGETS images and related manifest
	$(MAKE) image-build
	$(MAKE) image-push
	$(MAKE) manifest-build
	$(MAKE) manifest-push

.PHONY: build-catalog
build-catalog: catalog-build ## Build a catalog image

.PHONY: push-catalog
push-catalog: catalog-push ## Push a catalog image

.PHONY: catalog
catalog: ## Build and push a catalog image
	$(MAKE) catalog-build
	$(MAKE) catalog-push

.PHONY: build-bundle
build-bundle: bundle-build ## Build the bundle image

.PHONY: push-bundle
push-bundle: bundle-push ## Push the bundle image

.PHONY: bundle-all
bundle-all: ## Build and push the bundle image
	$(MAKE) bundle
	$(MAKE) bundle-build
	$(MAKE) bundle-push

.PHONY: bundle-deploy
bundle-deploy: ## Generate, build, push and deploy the bundle image via OLM
	$(MAKE) bundle-all
	$(MAKE) bundle-run
