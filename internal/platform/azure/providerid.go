package azure

import (
	"fmt"
	"regexp"
	"strings"
)

var providerIDRe = regexp.MustCompile(`^azure://(?P<id>/subscriptions/[^/]+/resourceGroups/(?P<rg>[^/]+)/providers/Microsoft\.Compute/virtualMachines/(?P<name>.+))$`)

// VirtualMachine is an Azure VM identified from a Kubernetes provider ID.
type VirtualMachine struct {
	ResourceGroup string
	Name          string
	// ID is the ARM resource ID, which is what a network interface records in
	// its own properties when it is attached to a VM.
	ID string
}

// ParseProviderID extracts VM identity from a Node's spec.providerID, which on
// Azure is azure:// followed by the VM's ARM resource ID.
//
// The ARM ID is what a network interface records when it is attached to a VM,
// and is therefore how a router node's interface is found.
func ParseProviderID(providerID string) (VirtualMachine, error) {
	m := providerIDRe.FindStringSubmatch(providerID)
	if m == nil {
		return VirtualMachine{}, fmt.Errorf("not an Azure VM provider ID: %q", providerID)
	}

	var vm VirtualMachine
	for i, name := range providerIDRe.SubexpNames() {
		switch name {
		case "id":
			vm.ID = m[i]
		case "rg":
			vm.ResourceGroup = m[i]
		case "name":
			vm.Name = m[i]
		}
	}
	return vm, nil
}

// sameResource reports whether two ARM resource IDs name the same thing.
// Azure is inconsistent about the case of the segment names between the
// providerID a node carries and the IDs its own API returns, so they are
// compared case-insensitively.
func sameResource(a, b string) bool {
	return strings.EqualFold(a, b)
}
