package client

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"stormdns-go/internal/logger"
)

func TestRunResolverScanAllowsZeroValidResolvers(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "scan.log")
	c := &Client{log: logger.NewWithFile("test", "INFO", logPath)}

	summary, err := c.RunResolverScan(context.Background())
	if err != nil {
		t.Fatalf("RunResolverScan returned error: %v", err)
	}
	if summary.Total != 0 || summary.Valid != 0 || summary.Rejected != 0 {
		t.Fatalf("unexpected summary: %+v", summary)
	}

	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "WD_SCAN event=complete total=0 valid=0 rejected=0") {
		t.Fatalf("completion line missing from log: %s", raw)
	}
}

func TestResolverScanMachineLines(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "scan.log")
	c := &Client{log: logger.NewWithFile("test", "INFO", logPath)}

	c.logResolverScanValid(Connection{ResolverLabel: "1.1.1.1:53"})
	c.logResolverScanRejected(Connection{ResolverLabel: "8.8.8.8:53"})
	c.logResolverScanComplete(ResolverScanSummary{Total: 3, Valid: 1, Rejected: 2})

	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	logText := string(raw)
	if !strings.Contains(logText, "WD_SCAN event=valid resolver=1.1.1.1:53") {
		t.Fatalf("valid line missing from log: %s", logText)
	}
	if !strings.Contains(logText, "WD_SCAN event=rejected resolver=8.8.8.8:53") {
		t.Fatalf("rejected line missing from log: %s", logText)
	}
	if !strings.Contains(logText, "WD_SCAN event=complete total=3 valid=1 rejected=2") {
		t.Fatalf("completion line missing from log: %s", logText)
	}
}
