/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
)

// The operator reads exactly one secret and is granted get on exactly
// that name. A cached read cannot be name-scoped -- serving it needs a
// list and a watch over the whole namespace, and resourceNames does not
// apply to collection verbs -- so the secret has to come from the API
// server directly or the Role has to be widened to match the informer.
func TestClientOptions_DoesNotCacheSecrets(t *testing.T) {
	cacheOpts := ClientOptions().Cache
	if cacheOpts == nil {
		t.Fatal("the client caches everything; reading the secret would need list and watch")
	}
	for _, obj := range cacheOpts.DisableFor {
		if _, ok := obj.(*corev1.Secret); ok {
			return
		}
	}
	t.Errorf("secrets are still cached: DisableFor is %v", cacheOpts.DisableFor)
}

// Nothing else should be taken out of the cache by accident. Nodes, pods
// and the downstream custom resources are read on every reconcile and
// are granted cluster-wide; serving those from the API server instead
// would turn each reconcile into a burst of live reads.
func TestClientOptions_CachesEverythingElse(t *testing.T) {
	if got := len(ClientOptions().Cache.DisableFor); got != 1 {
		t.Errorf("%d types bypass the cache, want only secrets", got)
	}
}
