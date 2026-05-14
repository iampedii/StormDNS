package client

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"stormdns-go/internal/logger"
)

func TestAcceptedResolverLogBypassesWarnThreshold(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "stormdns.log")
	c := &Client{log: logger.NewWithFile("test", "WARN", logPath)}
	counters := &mtuScanCounters{}
	conn := &Connection{
		Domain:        "v10.whitedns.shop",
		ResolverLabel: "1.1.1.1:53",
	}

	c.acceptConnectionMTUProbe(
		conn,
		mtuConnectionProbeResult{
			UploadBytes:   120,
			UploadChars:   180,
			DownloadBytes: 1400,
			ResolveTime:   10 * time.Millisecond,
		},
		counters,
		3,
	)

	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	logText := string(raw)
	if !strings.Contains(logText, "[INFO] ") ||
		!strings.Contains(logText, "Accepted (1/3): v10.whitedns.shop via 1.1.1.1:53") {
		t.Fatalf("accepted resolver line missing from WARN-level log: %s", logText)
	}
	if !strings.Contains(logText, "upload=120 | download=1400 | totals: valid=1, rejected=0") {
		t.Fatalf("accepted resolver MTU details missing from log: %s", logText)
	}
}
