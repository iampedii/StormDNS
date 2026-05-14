package client

import (
	"fmt"
	"slices"
	"strings"
	"time"
)

const resolverRuntimeStateHeartbeatInterval = 30 * time.Second

func (c *Client) finalizeValidResolvers(validConns []Connection) ([]Connection, int, int, int) {
	if c == nil {
		return nil, 0, 0, 0
	}

	c.balancer.RefreshValidConnections()
	_, minUpload, minDownload, minUploadChars := summarizeValidMTUConnections(c.connections)
	c.logResolverRuntimeState()
	return validConns, minUpload, minDownload, minUploadChars
}

func (c *Client) logResolverRuntimeState() {
	if c == nil || c.log == nil {
		return
	}
	active, standby, valid := c.resolverRuntimeSnapshot()
	line := c.resolverRuntimeStateLogLine(active, standby, valid)
	if !c.shouldEmitResolverRuntimeState(line, c.now()) {
		return
	}
	c.log.Machinef("%s", line)
}

func (c *Client) resolverRuntimeStateLogLine(active []string, standby []string, valid []string) string {
	return fmt.Sprintf(
		"WD_RESOLVERS active=%s standby=%s valid=%s",
		formatResolverRuntimeList(active),
		formatResolverRuntimeList(standby),
		formatResolverRuntimeList(valid),
	)
}

func (c *Client) shouldEmitResolverRuntimeState(line string, now time.Time) bool {
	if c == nil || line == "" {
		return false
	}
	c.resolverRuntimeLogMu.Lock()
	defer c.resolverRuntimeLogMu.Unlock()

	isHeartbeatDue := c.lastResolverRuntimeLogAt.IsZero() ||
		now.Sub(c.lastResolverRuntimeLogAt) >= resolverRuntimeStateHeartbeatInterval
	if line == c.lastResolverRuntimeLog && !isHeartbeatDue {
		return false
	}

	c.lastResolverRuntimeLog = line
	c.lastResolverRuntimeLogAt = now
	return true
}

func (c *Client) resolverRuntimeSnapshot() (active []string, standby []string, valid []string) {
	if c == nil {
		return nil, nil, nil
	}
	active = make([]string, 0, len(c.connections))
	valid = make([]string, 0, len(c.connections))

	for _, conn := range c.connections {
		if conn.Key == "" || conn.ResolverLabel == "" {
			continue
		}
		if conn.UploadMTUBytes > 0 && conn.DownloadMTUBytes > 0 {
			valid = append(valid, conn.ResolverLabel)
		}
		if conn.IsValid {
			active = append(active, conn.ResolverLabel)
		}
	}

	slices.Sort(active)
	slices.Sort(valid)
	return active, nil, valid
}

func formatResolverRuntimeList(values []string) string {
	if len(values) == 0 {
		return "-"
	}
	return strings.Join(values, ",")
}
