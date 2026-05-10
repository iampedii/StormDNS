package client

import (
	"testing"
	"time"

	"stormdns-go/internal/config"
)

func TestFinalizeValidResolversKeepsAllValidResolversActive(t *testing.T) {
	c := buildTestClientWithResolvers(config.ClientConfig{}, "fast", "wide", "slow")
	for idx := range c.connections {
		c.connections[idx].IsValid = true
		c.connections[idx].UploadMTUBytes = 100 + idx
		c.connections[idx].UploadMTUChars = 120 + idx
		c.connections[idx].DownloadMTUBytes = 180 + idx
	}
	c.balancer.RefreshValidConnections()

	valid, _, _, _ := summarizeValidMTUConnections(c.connections)
	selected, minUpload, minDownload, _ := c.finalizeValidResolvers(valid)

	if len(selected) != 3 {
		t.Fatalf("expected all valid resolvers to remain active, got %d", len(selected))
	}
	if minUpload != 100 || minDownload != 180 {
		t.Fatalf("expected MTU minima from all valid resolvers, got up=%d down=%d", minUpload, minDownload)
	}
	if c.balancer.ValidCount() != 3 {
		t.Fatalf("expected all resolvers active in balancer, got %d", c.balancer.ValidCount())
	}
}

func TestResolverRuntimeStateLogSuppressesDuplicateSnapshotsUntilHeartbeat(t *testing.T) {
	c := buildTestClientWithResolvers(config.ClientConfig{}, "active", "standby")
	now := time.Date(2026, 5, 7, 15, 0, 0, 0, time.UTC)

	line := "WD_RESOLVERS active=active standby=- valid=active,standby"
	if !c.shouldEmitResolverRuntimeState(line, now) {
		t.Fatal("expected first resolver state snapshot to be emitted")
	}
	if c.shouldEmitResolverRuntimeState(line, now.Add(time.Second)) {
		t.Fatal("expected duplicate resolver state snapshot to be suppressed")
	}
	if !c.shouldEmitResolverRuntimeState(line, now.Add(resolverRuntimeStateHeartbeatInterval)) {
		t.Fatal("expected duplicate resolver state snapshot to be emitted on heartbeat")
	}
	if !c.shouldEmitResolverRuntimeState(line+",new", now.Add(resolverRuntimeStateHeartbeatInterval+time.Second)) {
		t.Fatal("expected changed resolver state snapshot to be emitted immediately")
	}
}
