package gcp

import "testing"

// TestChunkRouterNodes covers the sort and the split at the NCC instance
// limit.
func TestChunkRouterNodes(t *testing.T) {
	mk := func(names ...string) []RouterNode {
		var out []RouterNode
		for _, n := range names {
			out = append(out, RouterNode{Name: n})
		}
		return out
	}

	chunks := ChunkRouterNodes(mk("b", "a", "c"), NCCMaxInstancesPerSpoke)
	if len(chunks) != 1 {
		t.Fatalf("got %d chunks, want 1", len(chunks))
	}
	if len(chunks[0]) != 3 {
		t.Fatalf("got %d nodes in the chunk, want 3", len(chunks[0]))
	}
	if chunks[0][0].Name != "a" {
		t.Errorf("first node = %q, want %q: chunks are sorted by name", chunks[0][0].Name, "a")
	}

	chunks = ChunkRouterNodes(mk("1", "2", "3", "4", "5", "6", "7", "8", "9"), 8)
	if len(chunks) != 2 {
		t.Fatalf("got %d chunks, want 2", len(chunks))
	}
	if len(chunks[0]) != 8 {
		t.Errorf("first chunk has %d nodes, want 8", len(chunks[0]))
	}
	if len(chunks[1]) != 1 {
		t.Errorf("second chunk has %d nodes, want 1", len(chunks[1]))
	}
	if chunks[1][0].Name != "9" {
		t.Errorf("overflow node = %q, want %q", chunks[1][0].Name, "9")
	}
}
