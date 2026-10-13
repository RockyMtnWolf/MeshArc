package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"tailscale.com/tsnet"
	"tailscaleohos.local/go_bridge/userspaceproxy"
)

var clashProxy userspaceproxy.Proxy

var coexistenceMu sync.Mutex

var localTCPServiceBridge = tcpServiceBridge{sessions: make(map[*tcpBridgeSession]struct{})}

type coexistenceStatus struct {
	Active             bool     `json:"active"`
	Address            string   `json:"address"`
	Error              string   `json:"error"`
	InboundTCPPorts    []uint16 `json:"inboundTCPPorts"`
	InboundTCPEnabled  bool     `json:"inboundTCPEnabled"`
	InboundTCPAllowAll bool     `json:"inboundTCPAllowAll"`
}

func proxyStatus(failure string) string {
	ports, bridgeActive, allowAll := localTCPServiceBridge.status()
	encoded, _ := json.Marshal(coexistenceStatus{
		Active:             clashProxy.Active(),
		Address:            "127.0.0.1:1055",
		Error:              failure,
		InboundTCPPorts:    ports,
		InboundTCPEnabled:  bridgeActive,
		InboundTCPAllowAll: allowAll,
	})
	return string(encoded)
}

type tcpServiceBridge struct {
	mu         sync.Mutex
	server     *tsnet.Server
	active     bool
	ports      map[uint16]struct{}
	allowAll   bool
	unregister func()
	sessions   map[*tcpBridgeSession]struct{}
}

type tcpBridgeSession struct {
	mu      sync.Mutex
	closed  bool
	port    uint16
	client  net.Conn
	service net.Conn
	once    sync.Once
}

func parseInboundTCPPorts(encoded string) (map[uint16]struct{}, error) {
	var requested []int
	if err := json.Unmarshal([]byte(encoded), &requested); err != nil {
		return nil, fmt.Errorf("ports must be a JSON array of TCP port numbers")
	}
	if requested == nil {
		return nil, fmt.Errorf("ports must be a JSON array, not null")
	}
	if len(requested) > 16 {
		return nil, fmt.Errorf("at most 16 inbound TCP ports may be enabled")
	}
	ports := make(map[uint16]struct{}, len(requested))
	for _, port := range requested {
		if port < 1 || port > 65535 {
			return nil, fmt.Errorf("inbound TCP port is outside 1..65535")
		}
		if port == 1055 {
			return nil, fmt.Errorf("the coexistence SOCKS port cannot be exposed as an inbound service")
		}
		ports[uint16(port)] = struct{}{}
	}
	return ports, nil
}

func parseInboundTCPPolicy(encoded string) (bool, map[uint16]struct{}, error) {
	trimmed := strings.TrimSpace(encoded)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return false, nil, fmt.Errorf("policy must be a JSON object")
	}
	var policy struct {
		AllowAll *bool `json:"allowAll"`
		Ports    []int `json:"ports"`
	}
	decoder := json.NewDecoder(strings.NewReader(trimmed))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&policy); err != nil {
		return false, nil, fmt.Errorf("invalid inbound TCP policy")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return false, nil, fmt.Errorf("policy contains trailing data")
	}
	if policy.AllowAll == nil || policy.Ports == nil {
		return false, nil, fmt.Errorf("policy requires allowAll and ports")
	}
	if len(policy.Ports) > 16 {
		return false, nil, fmt.Errorf("at most 16 inbound TCP ports may be enabled")
	}
	ports := make(map[uint16]struct{}, len(policy.Ports))
	for _, port := range policy.Ports {
		if port < 1 || port > 65535 {
			return false, nil, fmt.Errorf("inbound TCP port is outside 1..65535")
		}
		if port == 1055 {
			return false, nil, fmt.Errorf("the coexistence SOCKS port cannot be exposed as an inbound service")
		}
		ports[uint16(port)] = struct{}{}
	}
	return *policy.AllowAll, ports, nil
}

func (bridge *tcpServiceBridge) enable(server *tsnet.Server) {
	bridge.mu.Lock()
	if bridge.active && bridge.server == server && bridge.unregister != nil {
		bridge.mu.Unlock()
		return
	}
	bridge.server = server
	bridge.active = true
	bridge.mu.Unlock()
	remove := server.RegisterFallbackTCPHandler(bridge.handleFlow)
	bridge.mu.Lock()
	if bridge.active && bridge.server == server {
		bridge.unregister = remove
		bridge.mu.Unlock()
		return
	}
	bridge.mu.Unlock()
	remove()
}

func (bridge *tcpServiceBridge) setPorts(ports map[uint16]struct{}) error {
	return bridge.setPolicy(false, ports)
}

func (bridge *tcpServiceBridge) setPolicy(allowAll bool, ports map[uint16]struct{}) error {
	bridge.mu.Lock()
	if !bridge.active || bridge.server == nil || !clashProxy.Active() {
		bridge.mu.Unlock()
		return fmt.Errorf("coexistence SOCKS mode must be active before enabling inbound TCP bridges")
	}
	bridge.ports = ports
	bridge.allowAll = allowAll
	revoked := make([]*tcpBridgeSession, 0)
	for session := range bridge.sessions {
		if !bridge.allowsPortLocked(session.port) {
			revoked = append(revoked, session)
		}
	}
	bridge.mu.Unlock()
	for _, session := range revoked {
		session.close()
	}
	return nil
}

func (bridge *tcpServiceBridge) allowsPortLocked(port uint16) bool {
	if port == 1055 {
		return false
	}
	if bridge.allowAll {
		return true
	}
	_, ok := bridge.ports[port]
	return ok
}

func (bridge *tcpServiceBridge) status() ([]uint16, bool, bool) {
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	ports := make([]uint16, 0, len(bridge.ports))
	for port := range bridge.ports {
		ports = append(ports, port)
	}
	sort.Slice(ports, func(left, right int) bool { return ports[left] < ports[right] })
	return ports, bridge.active && (bridge.allowAll || len(ports) != 0), bridge.allowAll
}

func (bridge *tcpServiceBridge) handleFlow(_, destination netip.AddrPort) (func(net.Conn), bool) {
	bridge.mu.Lock()
	server := bridge.server
	portAllowed := bridge.allowsPortLocked(destination.Port())
	active := bridge.active && portAllowed
	bridge.mu.Unlock()
	if !active || server == nil {
		return nil, false
	}
	ipv4, ipv6 := server.TailscaleIPs()
	if destination.Addr() != ipv4 && destination.Addr() != ipv6 {
		return nil, false
	}
	return func(client net.Conn) {
		session := &tcpBridgeSession{client: client, port: destination.Port()}
		bridge.mu.Lock()
		if !bridge.active || bridge.server != server {
			bridge.mu.Unlock()
			session.close()
			return
		}
		if !bridge.allowsPortLocked(destination.Port()) {
			bridge.mu.Unlock()
			session.close()
			return
		}
		bridge.sessions[session] = struct{}{}
		bridge.mu.Unlock()
		go bridge.serve(session, destination.Port())
	}, true
}

func (bridge *tcpServiceBridge) serve(session *tcpBridgeSession, port uint16) {
	defer func() {
		session.close()
		bridge.mu.Lock()
		delete(bridge.sessions, session)
		bridge.mu.Unlock()
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	service, err := (&net.Dialer{}).DialContext(ctx, "tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(int(port))))
	cancel()
	if err != nil || !session.attachService(service) {
		if service != nil {
			_ = service.Close()
		}
		return
	}

	finished := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(service, session.client)
		finished <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(session.client, service)
		finished <- struct{}{}
	}()
	<-finished
	session.close()
	<-finished
}

func (session *tcpBridgeSession) attachService(service net.Conn) bool {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.closed {
		return false
	}
	session.service = service
	return true
}

func (session *tcpBridgeSession) close() {
	session.once.Do(func() {
		session.mu.Lock()
		session.closed = true
		client := session.client
		service := session.service
		session.mu.Unlock()
		if client != nil {
			_ = client.Close()
		}
		if service != nil {
			_ = service.Close()
		}
	})
}

func (bridge *tcpServiceBridge) disable() {
	bridge.mu.Lock()
	bridge.active = false
	bridge.server = nil
	bridge.ports = nil
	bridge.allowAll = false
	remove := bridge.unregister
	bridge.unregister = nil
	sessions := make([]*tcpBridgeSession, 0, len(bridge.sessions))
	for session := range bridge.sessions {
		sessions = append(sessions, session)
	}
	bridge.sessions = make(map[*tcpBridgeSession]struct{})
	bridge.mu.Unlock()
	if remove != nil {
		remove()
	}
	for _, session := range sessions {
		session.close()
	}
}

//export TSCoexistenceSetInboundTCPPorts
func TSCoexistenceSetInboundTCPPorts(encoded *C.char) *C.char {
	requested, err := parseInboundTCPPorts(C.GoString(encoded))
	if err != nil {
		return C.CString(proxyStatus(err.Error()))
	}
	coexistenceMu.Lock()
	defer coexistenceMu.Unlock()
	if err := localTCPServiceBridge.setPorts(requested); err != nil {
		return C.CString(proxyStatus(err.Error()))
	}
	return C.CString(proxyStatus(""))
}

//export TSCoexistenceSetInboundTCPPolicy
func TSCoexistenceSetInboundTCPPolicy(encoded *C.char) *C.char {
	allowAll, ports, err := parseInboundTCPPolicy(C.GoString(encoded))
	if err != nil {
		return C.CString(proxyStatus(err.Error()))
	}
	coexistenceMu.Lock()
	defer coexistenceMu.Unlock()
	if err := localTCPServiceBridge.setPolicy(allowAll, ports); err != nil {
		return C.CString(proxyStatus(err.Error()))
	}
	return C.CString(proxyStatus(""))
}

//export TSCoexistenceStart
func TSCoexistenceStart() *C.char {
	coexistenceMu.Lock()
	defer coexistenceMu.Unlock()
	harmonyBackend.mu.Lock()
	server := harmonyBackend.server
	ready := server != nil && !harmonyBackend.starting && !harmonyBackend.externalTun
	harmonyBackend.mu.Unlock()
	if !ready || !strings.Contains(harmonyBackend.status(), "state=Running") {
		return C.CString(proxyStatus("用户态后端未就绪；请先停止本应用系统 VPN，保留 ClashBox VPN。"))
	}
	if err := clashProxy.Start("127.0.0.1:1055", server.Dial); err != nil {
		return C.CString(proxyStatus("本地 SOCKS 端口 1055 不可用。"))
	}
	localTCPServiceBridge.enable(server)
	return C.CString(proxyStatus(""))
}

//export TSCoexistenceStop
func TSCoexistenceStop() *C.char {
	stopCoexistence()
	return C.CString(proxyStatus(""))
}

func stopCoexistence() {
	coexistenceMu.Lock()
	localTCPServiceBridge.disable()
	clashProxy.Stop()
	coexistenceMu.Unlock()
}

//export TSCoexistenceStatus
func TSCoexistenceStatus() *C.char {
	return C.CString(proxyStatus(""))
}
