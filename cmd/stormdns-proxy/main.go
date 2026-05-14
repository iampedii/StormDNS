package main

import (
	"context"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"hash/fnv"
	"log"
	"net"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"stormdns-go/internal/config"
	DnsParser "stormdns-go/internal/dnsparser"
	domainMatcher "stormdns-go/internal/domainmatcher"
	Enums "stormdns-go/internal/enums"
	"stormdns-go/internal/runtimepath"
	"stormdns-go/internal/security"
	VpnProto "stormdns-go/internal/vpnproto"
)

const (
	defaultListen        = "0.0.0.0:53"
	defaultBackends      = "172.30.0.11:53,172.30.0.12:53,172.30.0.13:53,172.30.0.14:53"
	defaultTimeout       = 4 * time.Second
	defaultSessionTTL    = 120 * time.Second
	defaultBusyCooldown  = 20 * time.Second
	defaultMaxSessions   = 245
	defaultCleanupPeriod = 5 * time.Second
)

type routeKey struct {
	id     uint8
	cookie uint8
}

type sessionRoute struct {
	backend int
	expires time.Time
}

type waiterKey struct {
	id    uint16
	qname string
}

type responseWaiter struct {
	ch chan []byte
}

type backend struct {
	name       string
	addr       *net.UDPAddr
	conn       *net.UDPConn
	waitersMu  sync.Mutex
	waiters    map[waiterKey][]responseWaiter
	active     atomic.Int64
	busyUntil  atomic.Int64
	sent       atomic.Uint64
	responses  atomic.Uint64
	timeouts   atomic.Uint64
	busy       atomic.Uint64
	accepted   atomic.Uint64
	sessionErr atomic.Uint64
}

func (b *backend) incActive() {
	b.active.Add(1)
}

func (b *backend) decActive() {
	for {
		current := b.active.Load()
		if current <= 0 {
			return
		}
		if b.active.CompareAndSwap(current, current-1) {
			return
		}
	}
}

type proxy struct {
	listen       *net.UDPConn
	backends     []*backend
	matcher      *domainMatcher.Matcher
	codec        *security.Codec
	timeout      time.Duration
	sessionTTL   time.Duration
	busyCooldown time.Duration
	maxSessions  int64

	mu       sync.Mutex
	routes   map[routeKey]sessionRoute
	initMap  map[string]sessionRoute
	rrCursor uint64
}

func main() {
	listenAddr := flag.String("listen", defaultListen, "UDP listen address")
	backendList := flag.String("backends", defaultBackends, "comma-separated backend UDP addresses")
	configPath := flag.String("config", "/root/server_config.toml", "StormDNS server config path")
	timeout := flag.Duration("timeout", defaultTimeout, "backend response timeout")
	sessionTTL := flag.Duration("session-ttl", defaultSessionTTL, "local session route TTL")
	busyCooldown := flag.Duration("busy-cooldown", defaultBusyCooldown, "backend cooldown after SESSION_BUSY")
	maxSessions := flag.Int64("max-sessions", defaultMaxSessions, "soft active-session limit per backend")
	flag.Parse()

	cfg, err := config.LoadServerConfigWithOverrides(runtimepath.Resolve(*configPath), config.ServerConfigOverrides{})
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	keyInfo, err := security.EnsureServerEncryptionKey(cfg)
	if err != nil {
		log.Fatalf("load encryption key: %v", err)
	}
	codec, err := security.NewCodecFromConfig(cfg, keyInfo.Key)
	if err != nil {
		log.Fatalf("init codec: %v", err)
	}

	udpAddr, err := net.ResolveUDPAddr("udp", *listenAddr)
	if err != nil {
		log.Fatalf("resolve listen addr: %v", err)
	}
	listener, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", *listenAddr, err)
	}
	defer listener.Close()

	backends, err := openBackends(*backendList)
	if err != nil {
		log.Fatalf("open backends: %v", err)
	}
	for _, b := range backends {
		defer b.conn.Close()
	}

	p := &proxy{
		listen:       listener,
		backends:     backends,
		matcher:      domainMatcher.New(cfg.Domain, cfg.MinVPNLabelLength),
		codec:        codec,
		timeout:      *timeout,
		sessionTTL:   *sessionTTL,
		busyCooldown: *busyCooldown,
		maxSessions:  *maxSessions,
		routes:       make(map[routeKey]sessionRoute),
		initMap:      make(map[string]sessionRoute),
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	for idx := range p.backends {
		go p.readBackend(ctx, idx)
	}
	go p.cleanupLoop(ctx)
	go p.statsLoop(ctx)

	log.Printf("stormdns-proxy listening on %s with %d backends", listener.LocalAddr(), len(backends))
	p.serve(ctx)
}

func openBackends(csv string) ([]*backend, error) {
	parts := strings.Split(csv, ",")
	var out []*backend
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		addr, err := net.ResolveUDPAddr("udp", part)
		if err != nil {
			return nil, err
		}
		conn, err := net.DialUDP("udp", nil, addr)
		if err != nil {
			return nil, err
		}
		out = append(out, &backend{
			name:    part,
			addr:    addr,
			conn:    conn,
			waiters: make(map[waiterKey][]responseWaiter),
		})
	}
	if len(out) == 0 {
		return nil, errors.New("no backends configured")
	}
	return out, nil
}

func (p *proxy) serve(ctx context.Context) {
	buf := make([]byte, 65535)
	for {
		_ = p.listen.SetReadDeadline(time.Now().Add(time.Second))
		n, client, err := p.listen.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			log.Printf("read client: %v", err)
			continue
		}
		packet := make([]byte, n)
		copy(packet, buf[:n])
		go p.handleClientPacket(packet, client)
	}
}

func (p *proxy) handleClientPacket(packet []byte, client *net.UDPAddr) {
	parsed, decision, vpnPacket, key, err := p.parseRequest(packet)
	if err != nil || decision.Action != domainMatcher.ActionProcess {
		p.forwardSimple(packet, client, 0)
		return
	}

	if vpnPacket.PacketType == Enums.PACKET_SESSION_INIT {
		p.handleSessionInit(packet, client, parsed, vpnPacket)
		return
	}

	backendIdx, ok := p.lookupRoute(key)
	if !ok {
		backendIdx = p.fallbackBackend(key)
	}
	resp, err := p.forward(packet, parsed, backendIdx)
	if err == nil && len(resp) > 0 {
		_, _ = p.listen.WriteToUDP(resp, client)
	}
	if vpnPacket.PacketType == Enums.PACKET_SESSION_CLOSE {
		p.dropRoute(key, backendIdx)
	}
}

func (p *proxy) handleSessionInit(packet []byte, client *net.UDPAddr, parsed DnsParser.LitePacket, vpnPacket VpnProto.Packet) {
	initKey := string(vpnPacket.Payload)
	if idx, ok := p.lookupInit(initKey); ok {
		resp, err := p.forward(packet, parsed, idx)
		if err == nil && len(resp) > 0 {
			p.observeResponse(idx, initKey, resp)
			_, _ = p.listen.WriteToUDP(resp, client)
			return
		}
	}

	order := p.backendOrder()
	var lastResp []byte
	for _, idx := range order {
		if !p.backendAvailable(idx) {
			continue
		}
		resp, err := p.forward(packet, parsed, idx)
		if err != nil || len(resp) == 0 {
			continue
		}
		lastResp = resp
		packetType := p.observeResponse(idx, initKey, resp)
		if packetType == Enums.PACKET_SESSION_BUSY {
			p.markBusy(idx)
			continue
		}
		_, _ = p.listen.WriteToUDP(resp, client)
		return
	}

	if len(lastResp) > 0 {
		_, _ = p.listen.WriteToUDP(lastResp, client)
	}
}

func (p *proxy) parseRequest(packet []byte) (DnsParser.LitePacket, domainMatcher.Decision, VpnProto.Packet, routeKey, error) {
	parsed, err := DnsParser.ParseDNSRequestLite(packet)
	if err != nil {
		return DnsParser.LitePacket{}, domainMatcher.Decision{}, VpnProto.Packet{}, routeKey{}, err
	}
	decision := p.matcher.Match(parsed)
	if decision.Action != domainMatcher.ActionProcess {
		return parsed, decision, VpnProto.Packet{}, routeKey{}, nil
	}
	vpnPacket, err := VpnProto.ParseFromLabels(decision.Labels, p.codec)
	if err != nil {
		return parsed, decision, VpnProto.Packet{}, routeKey{}, err
	}
	return parsed, decision, vpnPacket, routeKey{id: vpnPacket.SessionID, cookie: vpnPacket.SessionCookie}, nil
}

func (p *proxy) forwardSimple(packet []byte, client *net.UDPAddr, idx int) {
	parsed, err := DnsParser.ParseDNSRequestLite(packet)
	if err != nil {
		return
	}
	resp, err := p.forward(packet, parsed, idx)
	if err == nil && len(resp) > 0 {
		_, _ = p.listen.WriteToUDP(resp, client)
	}
}

func (p *proxy) forward(packet []byte, parsed DnsParser.LitePacket, idx int) ([]byte, error) {
	if idx < 0 || idx >= len(p.backends) {
		idx = 0
	}
	b := p.backends[idx]
	key := waiterKey{id: parsed.Header.ID, qname: parsed.FirstQuestion.Name}
	waiter := responseWaiter{ch: make(chan []byte, 1)}

	b.waitersMu.Lock()
	b.waiters[key] = append(b.waiters[key], waiter)
	b.waitersMu.Unlock()

	b.sent.Add(1)
	_, err := b.conn.Write(packet)
	if err != nil {
		p.removeWaiter(b, key, waiter)
		return nil, err
	}

	timer := time.NewTimer(p.timeout)
	defer timer.Stop()
	select {
	case resp := <-waiter.ch:
		return resp, nil
	case <-timer.C:
		p.removeWaiter(b, key, waiter)
		b.timeouts.Add(1)
		return nil, os.ErrDeadlineExceeded
	}
}

func (p *proxy) readBackend(ctx context.Context, idx int) {
	b := p.backends[idx]
	buf := make([]byte, 65535)
	for {
		_ = b.conn.SetReadDeadline(time.Now().Add(time.Second))
		n, err := b.conn.Read(buf)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			log.Printf("read backend %s: %v", b.name, err)
			continue
		}
		resp := make([]byte, n)
		copy(resp, buf[:n])
		parsed, err := DnsParser.ParsePacket(resp)
		if err != nil || len(parsed.Questions) == 0 {
			continue
		}
		key := waiterKey{id: parsed.Header.ID, qname: parsed.Questions[0].Name}
		b.waitersMu.Lock()
		waiters := b.waiters[key]
		if len(waiters) > 0 {
			waiter := waiters[0]
			if len(waiters) == 1 {
				delete(b.waiters, key)
			} else {
				b.waiters[key] = waiters[1:]
			}
			b.waitersMu.Unlock()
			b.responses.Add(1)
			waiter.ch <- resp
			continue
		}
		b.waitersMu.Unlock()
	}
}

func (p *proxy) observeResponse(idx int, initKey string, resp []byte) uint8 {
	packet, err := DnsParser.ExtractVPNResponse(resp, false)
	if err != nil {
		packet, err = DnsParser.ExtractVPNResponse(resp, true)
	}
	if err != nil {
		return 0
	}
	b := p.backends[idx]
	switch packet.PacketType {
	case Enums.PACKET_SESSION_ACCEPT:
		if len(packet.Payload) >= 2 {
			key := routeKey{id: packet.Payload[0], cookie: packet.Payload[1]}
			p.setRoute(key, initKey, idx)
			b.accepted.Add(1)
		}
	case Enums.PACKET_SESSION_BUSY:
		b.busy.Add(1)
	case Enums.PACKET_ERROR_DROP:
		b.sessionErr.Add(1)
	}
	return packet.PacketType
}

func (p *proxy) setRoute(key routeKey, initKey string, idx int) {
	expires := time.Now().Add(p.sessionTTL)
	p.mu.Lock()
	if old, ok := p.routes[key]; !ok {
		p.backends[idx].incActive()
	} else if old.backend != idx {
		p.backends[old.backend].decActive()
		p.backends[idx].incActive()
	}
	p.routes[key] = sessionRoute{backend: idx, expires: expires}
	if initKey != "" {
		p.initMap[initKey] = sessionRoute{backend: idx, expires: expires}
	}
	p.mu.Unlock()
}

func (p *proxy) lookupRoute(key routeKey) (int, bool) {
	if key.id == 0 {
		return 0, false
	}
	now := time.Now()
	p.mu.Lock()
	route, ok := p.routes[key]
	if ok && now.Before(route.expires) {
		route.expires = now.Add(p.sessionTTL)
		p.routes[key] = route
		p.mu.Unlock()
		return route.backend, true
	}
	if ok {
		delete(p.routes, key)
		p.backends[route.backend].decActive()
	}
	p.mu.Unlock()
	return 0, false
}

func (p *proxy) lookupInit(key string) (int, bool) {
	if key == "" {
		return 0, false
	}
	now := time.Now()
	p.mu.Lock()
	route, ok := p.initMap[key]
	if ok && now.Before(route.expires) {
		p.mu.Unlock()
		return route.backend, true
	}
	if ok {
		delete(p.initMap, key)
	}
	p.mu.Unlock()
	return 0, false
}

func (p *proxy) dropRoute(key routeKey, idx int) {
	if key.id == 0 {
		return
	}
	p.mu.Lock()
	if route, ok := p.routes[key]; ok {
		delete(p.routes, key)
		p.backends[route.backend].decActive()
	}
	p.mu.Unlock()
}

func (p *proxy) backendAvailable(idx int) bool {
	b := p.backends[idx]
	if time.Now().UnixNano() < b.busyUntil.Load() {
		return false
	}
	return b.active.Load() < p.maxSessions
}

func (p *proxy) markBusy(idx int) {
	p.backends[idx].busyUntil.Store(time.Now().Add(p.busyCooldown).UnixNano())
}

func (p *proxy) backendOrder() []int {
	type scored struct {
		idx    int
		active int64
		busy   bool
		rr     uint64
	}
	now := time.Now().UnixNano()
	base := p.rrCursor
	p.rrCursor++
	items := make([]scored, 0, len(p.backends))
	for idx, b := range p.backends {
		items = append(items, scored{
			idx:    idx,
			active: b.active.Load(),
			busy:   now < b.busyUntil.Load(),
			rr:     (uint64(idx) + base) % uint64(len(p.backends)),
		})
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].busy != items[j].busy {
			return !items[i].busy
		}
		if items[i].active != items[j].active {
			return items[i].active < items[j].active
		}
		return items[i].rr < items[j].rr
	})
	out := make([]int, len(items))
	for i := range items {
		out[i] = items[i].idx
	}
	return out
}

func (p *proxy) fallbackBackend(key routeKey) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte{key.id, key.cookie})
	return int(h.Sum32() % uint32(len(p.backends)))
}

func (p *proxy) removeWaiter(b *backend, key waiterKey, waiter responseWaiter) {
	b.waitersMu.Lock()
	defer b.waitersMu.Unlock()
	waiters := b.waiters[key]
	for i := range waiters {
		if waiters[i].ch == waiter.ch {
			waiters = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(waiters) == 0 {
		delete(b.waiters, key)
	} else {
		b.waiters[key] = waiters
	}
}

func (p *proxy) cleanupLoop(ctx context.Context) {
	ticker := time.NewTicker(defaultCleanupPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.cleanupExpired()
		}
	}
}

func (p *proxy) cleanupExpired() {
	now := time.Now()
	p.mu.Lock()
	for key, route := range p.routes {
		if now.After(route.expires) {
			delete(p.routes, key)
			p.backends[route.backend].decActive()
		}
	}
	for key, route := range p.initMap {
		if now.After(route.expires) {
			delete(p.initMap, key)
		}
	}
	p.mu.Unlock()
}

func (p *proxy) statsLoop(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			var parts []string
			for i, b := range p.backends {
				parts = append(parts, fmt.Sprintf(
					"b%d=%s active=%d sent=%d resp=%d timeout=%d accept=%d busy=%d",
					i+1, b.name, b.active.Load(), b.sent.Load(), b.responses.Load(),
					b.timeouts.Load(), b.accepted.Load(), b.busy.Load(),
				))
			}
			log.Printf("stats %s", strings.Join(parts, " | "))
		}
	}
}

func dnsID(packet []byte) uint16 {
	if len(packet) < 2 {
		return 0
	}
	return binary.BigEndian.Uint16(packet[:2])
}
