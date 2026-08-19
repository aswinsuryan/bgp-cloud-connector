package gcp

import (
	"fmt"
	"regexp"
)

var providerIDRe = regexp.MustCompile(`^gce://(?P<project>[^/]+)/(?P<zone>[^/]+)/(?P<name>.+)$`)

// Instance is a GCE instance identified from a Kubernetes provider ID.
type Instance struct {
	Project  string
	Zone     string
	Name     string
	SelfLink string
}

// ParseProviderID extracts GCE instance identity from a Node's
// spec.providerID, which has the form gce://PROJECT/ZONE/NAME.
//
// The controller hands the platform a cloud-neutral node carrying a provider
// ID and nothing else, so this is where a GCE instance is named.
func ParseProviderID(providerID string) (Instance, error) {
	m := providerIDRe.FindStringSubmatch(providerID)
	if m == nil {
		return Instance{}, fmt.Errorf("not a GCE provider ID: %q", providerID)
	}

	var inst Instance
	for i, name := range providerIDRe.SubexpNames() {
		switch name {
		case "project":
			inst.Project = m[i]
		case "zone":
			inst.Zone = m[i]
		case "name":
			inst.Name = m[i]
		}
	}
	inst.SelfLink = SelfLink(inst.Project, inst.Zone, inst.Name)
	return inst, nil
}

// SelfLink returns the fully qualified GCE instance URL, which is how both
// Cloud Router peers and NCC spokes refer to an instance.
func SelfLink(project, zone, name string) string {
	return fmt.Sprintf("https://www.googleapis.com/compute/v1/projects/%s/zones/%s/instances/%s", project, zone, name)
}
