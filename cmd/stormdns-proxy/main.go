package main

import (
	"context"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
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
	"stormdns-go/internal/netbind"
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
	defaultMissCooldown  = 2 * time.Second
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
	ch chan backendResponse
}

type backendResponse struct {
	packet []byte
	err    error
}

type clientRequest struct {
	packet []byte
	client *net.UDPAddr
	local  net.IP
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
	readers      int
	workers      int
	queueDepth   int

	mu          sync.Mutex
	routes      map[routeKey]sessionRoute
	initMap     map[string]sessionRoute
	missMap     map[routeKey]time.Time
	rrCursor    atomic.Uint64
	clientDrops atomic.Uint64
	routeMisses atomic.Uint64
	recovered   atomic.Uint64
	collisions  atomic.Uint64
}

func main() {
	listenAddr := flag.String("listen", defaultListen, "UDP listen address")
	backendList := flag.String("backends", defaultBackends, "comma-separated backend UDP addresses")
	configPath := flag.String("config", "/root/server_config.toml", "StormDNS server config path")
	timeout := flag.Duration("timeout", defaultTimeout, "backend response timeout")
	sessionTTL := flag.Duration("session-ttl", defaultSessionTTL, "local session route TTL")
	busyCooldown := flag.Duration("busy-cooldown", defaultBusyCooldown, "backend cooldown after SESSION_BUSY")
	maxSessions := flag.Int64("max-sessions", defaultMaxSessions, "soft active-session limit per backend")
	socketBuffer := flag.Int("socket-buffer", 0, "UDP socket read/write buffer bytes; default uses SOCKET_BUFFER_SIZE from config")
	readers := flag.Int("readers", 0, "client UDP reader goroutines; default uses UDP_READERS from config")
	workers := flag.Int("workers", 0, "client packet worker goroutines; default uses DNS_REQUEST_WORKERS from config")
	queueDepth := flag.Int("queue", 0, "client packet queue depth; default uses MAX_CONCURRENT_REQUESTS from config")
	ingressInterfaceFlag := flag.String("ingress-interface", "", "bind client UDP listener to a network interface; default uses INGRESS_INTERFACE from config")
	flag.Parse()

	cfg, err := config.LoadServerConfigWithOverrides(runtimepath.Resolve(*configPath), config.ServerConfigOverrides{})
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	bufferSize := cfg.SocketBufferSize
	if *socketBuffer > 0 {
		bufferSize = *socketBuffer
	}
	clientReaders := cfg.UDPReaders
	if *readers > 0 {
		clientReaders = *readers
	}
	if clientReaders < 1 {
		clientReaders = 1
	}
	clientWorkers := cfg.DNSRequestWorkers
	if *workers > 0 {
		clientWorkers = *workers
	}
	if clientWorkers < 1 {
		clientWorkers = 1
	}
	clientQueueDepth := cfg.MaxConcurrentRequests
	if *queueDepth > 0 {
		clientQueueDepth = *queueDepth
	}
	if clientQueueDepth < clientWorkers {
		clientQueueDepth = clientWorkers
	}
	ingressInterface := netbind.NormalizeInterface(*ingressInterfaceFlag)
	if ingressInterface == "" {
		ingressInterface = cfg.IngressInterface
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
	listener, err := netbind.ListenUDP(context.Background(), "udp", udpAddr.String(), ingressInterface)
	if err != nil {
		log.Fatalf("listen %s: %v", *listenAddr, err)
	}
	defer listener.Close()
	if err := enableDestinationPacketInfo(listener); err != nil {
		log.Fatalf("enable destination packet info: %v", err)
	}
	configureUDPBuffers("client listener", listener, bufferSize)

	backends, err := openBackends(*backendList, bufferSize)
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
		readers:      clientReaders,
		workers:      clientWorkers,
		queueDepth:   clientQueueDepth,
		routes:       make(map[routeKey]sessionRoute),
		initMap:      make(map[string]sessionRoute),
		missMap:      make(map[routeKey]time.Time),
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	for idx := range p.backends {
		go p.readBackend(ctx, idx)
	}
	go p.cleanupLoop(ctx)
	go p.statsLoop(ctx)

	log.Printf(
		"stormdns-proxy listening on %s ingress-interface=%q with %d backends readers=%d workers=%d queue=%d socket-buffer=%d",
		listener.LocalAddr(), ingressInterface, len(backends), clientReaders, clientWorkers, clientQueueDepth, bufferSize,
	)
	p.serve(ctx)
}

func configureUDPBuffers(name string, conn *net.UDPConn, bytes int) {
	if conn == nil || bytes <= 0 {
		return
	}
	if err := conn.SetReadBuffer(bytes); err != nil {
		log.Printf("%s UDP read buffer setup failed: %v", name, err)
	}
	if err := conn.SetWriteBuffer(bytes); err != nil {
		log.Printf("%s UDP write buffer setup failed: %v", name, err)
	}
}

func openBackends(csv string, socketBuffer int) ([]*backend, error) {
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
		configureUDPBuffers("backend "+part, conn, socketBuffer)
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
	reqCh := make(chan clientRequest, p.queueDepth)
	var workerWG sync.WaitGroup
	for workerID := 1; workerID <= p.workers; workerID++ {
		workerWG.Add(1)
		go p.clientWorker(ctx, reqCh, &workerWG)
	}

	var readerWG sync.WaitGroup
	for readerID := 1; readerID <= p.readers; readerID++ {
		readerWG.Add(1)
		go p.clientReader(ctx, reqCh, &readerWG)
	}

	<-ctx.Done()
	_ = p.listen.Close()
	readerWG.Wait()
	close(reqCh)
	workerWG.Wait()
}

func (p *proxy) clientReader(ctx context.Context, reqCh chan<- clientRequest, wg *sync.WaitGroup) {
	defer wg.Done()
	buf := make([]byte, 65535)
	oob := make([]byte, packetInfoOOBSize())
	for {
		n, client, local, err := readClientPacket(p.listen, buf, oob)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("read client: %v", err)
			continue
		}
		packet := make([]byte, n)
		copy(packet, buf[:n])
		select {
		case reqCh <- clientRequest{packet: packet, client: client, local: local}:
		case <-ctx.Done():
			return
		default:
			p.clientDrops.Add(1)
		}
	}
}

func (p *proxy) clientWorker(ctx context.Context, reqCh <-chan clientRequest, wg *sync.WaitGroup) {
	defer wg.Done()
	for {
		select {
		case <-ctx.Done():
			return
		case req, ok := <-reqCh:
			if !ok {
				return
			}
			p.handleClientPacket(req)
		}
	}
}

func (p *proxy) handleClientPacket(req clientRequest) {
	packet := req.packet
	parsed, decision, vpnPacket, key, err := p.parseRequest(packet)
	if err != nil || decision.Action != domainMatcher.ActionProcess {
		p.forwardSimple(req, 0)
		return
	}

	if vpnPacket.PacketType == Enums.PACKET_SESSION_INIT {
		p.handleSessionInit(req, parsed, vpnPacket)
		return
	}

	backendIdx, ok := p.lookupRoute(key)
	if !ok {
		p.routeMisses.Add(1)
		if p.recoverRoute(req, parsed, vpnPacket, key) {
			return
		}
		return
	}
	resp, err := p.forward(packet, parsed, backendIdx)
	if err == nil && len(resp) > 0 {
		p.writeClientResponse(resp, req)
	}
	if vpnPacket.PacketType == Enums.PACKET_SESSION_CLOSE {
		p.dropRoute(key, backendIdx)
	}
}

func (p *proxy) recoverRoute(req clientRequest, parsed DnsParser.LitePacket, vpnPacket VpnProto.Packet, key routeKey) bool {
	if p.routeMissCoolingDown(key) {
		return false
	}

	for _, idx := range p.backendOrder() {
		if p.backendBusy(idx) {
			continue
		}
		resp, err := p.forward(req.packet, parsed, idx)
		if err != nil || len(resp) == 0 {
			continue
		}
		packetType := vpnResponseType(resp)
		if packetType == Enums.PACKET_ERROR_DROP || packetType == Enums.PACKET_SESSION_BUSY || packetType == 0 {
			continue
		}

		p.setRoute(key, "", idx)
		p.recovered.Add(1)
		p.writeClientResponse(resp, req)
		if vpnPacket.PacketType == Enums.PACKET_SESSION_CLOSE {
			p.dropRoute(key, idx)
		}
		return true
	}

	p.rememberRouteMiss(key)
	return false
}

func vpnResponseType(resp []byte) uint8 {
	packet, err := DnsParser.ExtractVPNResponse(resp, false)
	if err != nil {
		packet, err = DnsParser.ExtractVPNResponse(resp, true)
	}
	if err != nil {
		return 0
	}
	return packet.PacketType
}

func (p *proxy) routeMissCoolingDown(key routeKey) bool {
	now := time.Now()
	p.mu.Lock()
	defer p.mu.Unlock()

	until, ok := p.missMap[key]
	if !ok {
		return false
	}
	if now.Before(until) {
		return true
	}
	delete(p.missMap, key)
	return false
}

func (p *proxy) rememberRouteMiss(key routeKey) {
	p.mu.Lock()
	p.missMap[key] = time.Now().Add(defaultMissCooldown)
	p.mu.Unlock()
}

func (p *proxy) handleSessionInit(req clientRequest, parsed DnsParser.LitePacket, vpnPacket VpnProto.Packet) {
	packet := req.packet
	initKey := string(vpnPacket.Payload)
	if idx, ok := p.lookupInit(initKey); ok {
		resp, err := p.forward(packet, parsed, idx)
		if err == nil && len(resp) > 0 {
			p.observeResponse(idx, initKey, resp)
			p.writeClientResponse(resp, req)
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
		p.writeClientResponse(resp, req)
		return
	}

	if len(lastResp) > 0 {
		p.writeClientResponse(lastResp, req)
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

func (p *proxy) forwardSimple(req clientRequest, idx int) {
	parsed, err := DnsParser.ParseDNSRequestLite(req.packet)
	if err != nil {
		return
	}
	resp, err := p.forward(req.packet, parsed, idx)
	if err == nil && len(resp) > 0 {
		p.writeClientResponse(resp, req)
	}
}

func (p *proxy) writeClientResponse(packet []byte, req clientRequest) {
	if err := writeClientPacket(p.listen, packet, req.client, req.local); err != nil {
		log.Printf("write client %s via %s: %v", req.client, req.local, err)
	}
}

func (p *proxy) forward(packet []byte, parsed DnsParser.LitePacket, idx int) ([]byte, error) {
	if idx < 0 || idx >= len(p.backends) {
		idx = 0
	}
	b := p.backends[idx]
	key := waiterKey{id: parsed.Header.ID, qname: parsed.FirstQuestion.Name}
	waiter := responseWaiter{ch: make(chan backendResponse, 1)}

	b.waitersMu.Lock()
	b.waiters[key] = append(b.waiters[key], waiter)
	b.waitersMu.Unlock()

	b.sent.Add(1)
	_, err := b.conn.Write(packet)
	if err != nil {
		p.removeWaiter(b, key, waiter)
		p.markBusy(idx)
		return nil, err
	}

	timer := time.NewTimer(p.timeout)
	defer timer.Stop()
	select {
	case result := <-waiter.ch:
		if result.err != nil {
			return nil, result.err
		}
		return result.packet, nil
	case <-timer.C:
		p.removeWaiter(b, key, waiter)
		p.markBusy(idx)
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
			p.markBusy(idx)
			p.failBackendWaiters(b, err)
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
			waiter.ch <- backendResponse{packet: resp}
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
			if p.setRoute(key, initKey, idx) {
				b.accepted.Add(1)
			} else {
				b.sessionErr.Add(1)
				p.collisions.Add(1)
				return Enums.PACKET_SESSION_BUSY
			}
		}
	case Enums.PACKET_SESSION_BUSY:
		b.busy.Add(1)
	case Enums.PACKET_ERROR_DROP:
		b.sessionErr.Add(1)
	}
	return packet.PacketType
}

func (p *proxy) setRoute(key routeKey, initKey string, idx int) bool {
	expires := time.Now().Add(p.sessionTTL)
	p.mu.Lock()
	defer p.mu.Unlock()
	if old, ok := p.routes[key]; !ok {
		p.backends[idx].incActive()
	} else if old.backend != idx {
		return false
	}
	p.routes[key] = sessionRoute{backend: idx, expires: expires}
	if initKey != "" {
		p.initMap[initKey] = sessionRoute{backend: idx, expires: expires}
	}
	return true
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
	if p.backendBusy(idx) {
		return false
	}
	return b.active.Load() < p.maxSessions
}

func (p *proxy) backendBusy(idx int) bool {
	return time.Now().UnixNano() < p.backends[idx].busyUntil.Load()
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
	base := p.rrCursor.Add(1) - 1
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

func (p *proxy) failBackendWaiters(b *backend, err error) {
	b.waitersMu.Lock()
	pending := b.waiters
	b.waiters = make(map[waiterKey][]responseWaiter)
	b.waitersMu.Unlock()

	for _, waiters := range pending {
		for _, waiter := range waiters {
			select {
			case waiter.ch <- backendResponse{err: err}:
			default:
			}
		}
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
	for key, until := range p.missMap {
		if now.After(until) {
			delete(p.missMap, key)
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
			log.Printf("stats drops=%d route_miss=%d recovered=%d collisions=%d %s", p.clientDrops.Load(), p.routeMisses.Load(), p.recovered.Load(), p.collisions.Load(), strings.Join(parts, " | "))
		}
	}
}

func dnsID(packet []byte) uint16 {
	if len(packet) < 2 {
		return 0
	}
	return binary.BigEndian.Uint16(packet[:2])
}
