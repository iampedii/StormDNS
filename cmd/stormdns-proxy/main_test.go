package main

import (
	"testing"
	"time"
)

func newTestProxy() *proxy {
	return &proxy{
		backends:   []*backend{{}, {}},
		sessionTTL: time.Minute,
		routes:     make(map[routeKey]sessionRoute),
		initMap:    make(map[string]sessionRoute),
		missMap:    make(map[routeKey]time.Time),
	}
}

func TestRouteCollisionDoesNotOverwriteExistingBackend(t *testing.T) {
	p := newTestProxy()
	key := routeKey{id: 7, cookie: 99}

	if ok := p.setRoute(key, "first-init", 0); !ok {
		t.Fatal("first route insert failed")
	}
	if ok := p.setRoute(key, "second-init", 1); ok {
		t.Fatal("colliding route insert unexpectedly succeeded")
	}

	if got, ok := p.lookupRoute(key); !ok || got != 0 {
		t.Fatalf("route after collision = %d, %t; want 0, true", got, ok)
	}
	if got := p.backends[0].active.Load(); got != 1 {
		t.Fatalf("backend 0 active = %d; want 1", got)
	}
	if got := p.backends[1].active.Load(); got != 0 {
		t.Fatalf("backend 1 active = %d; want 0", got)
	}
	if _, ok := p.lookupInit("second-init"); ok {
		t.Fatal("colliding init route was recorded")
	}
}

func TestInitRouteRetriesUseOriginalBackend(t *testing.T) {
	p := newTestProxy()
	key := routeKey{id: 8, cookie: 10}

	if ok := p.setRoute(key, "same-init", 1); !ok {
		t.Fatal("route insert failed")
	}

	if got, ok := p.lookupInit("same-init"); !ok || got != 1 {
		t.Fatalf("init route = %d, %t; want 1, true", got, ok)
	}
}

func TestRouteMissCooldown(t *testing.T) {
	p := newTestProxy()
	key := routeKey{id: 9, cookie: 11}

	if p.routeMissCoolingDown(key) {
		t.Fatal("new key should not be cooling down")
	}
	p.rememberRouteMiss(key)
	if !p.routeMissCoolingDown(key) {
		t.Fatal("remembered key should be cooling down")
	}
}
