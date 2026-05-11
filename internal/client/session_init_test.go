package client

import (
	"testing"

	"stormdns-go/internal/config"
)

func TestNextSessionInitAttemptUsesBalancerSnapshotConnection(t *testing.T) {
	c := buildTestClientWithResolvers(config.ClientConfig{}, "a", "b")

	originalDomain := c.connections[0].Domain
	c.connections[0].Domain = "mutated.example.com"

	conn, _, _, err := c.nextSessionInitAttempt()
	if err != nil {
		t.Fatalf("nextSessionInitAttempt returned error: %v", err)
	}

	if conn.Domain != originalDomain {
		t.Fatalf("expected session init to use balancer snapshot domain %q, got %q", originalDomain, conn.Domain)
	}
}

func TestNextSessionInitAttemptsFansOutAcrossSnapshotConnections(t *testing.T) {
	c := buildTestClientWithResolvers(config.ClientConfig{
		UploadSetupPacketDuplicationCount:   4,
		DownloadSetupPacketDuplicationCount: 4,
	}, "a", "b", "c", "d")

	attempts, err := c.nextSessionInitAttempts(c.sessionInitFanoutCount())
	if err != nil {
		t.Fatalf("nextSessionInitAttempts returned error: %v", err)
	}
	if len(attempts) != 4 {
		t.Fatalf("unexpected fanout count: got=%d want=4", len(attempts))
	}

	seen := map[string]bool{}
	for _, attempt := range attempts {
		seen[attempt.conn.Key] = true
	}
	for _, key := range []string{"a", "b", "c", "d"} {
		if !seen[key] {
			t.Fatalf("expected fanout to include resolver %q; got=%v", key, seen)
		}
	}
}
