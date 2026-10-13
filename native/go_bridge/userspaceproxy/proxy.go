package userspaceproxy

import (
	"context"
	"net"
	"sync"

	"tailscale.com/net/socks5"
)

type Proxy struct {
	mu          sync.Mutex
	listener    net.Listener
	connections map[*trackedConnection]bool
	cancel      context.CancelFunc
}

type trackedConnection struct {
	net.Conn
	owner *Proxy
}

type trackingListener struct {
	net.Listener
	owner *Proxy
}

func (listener *trackingListener) Accept() (net.Conn, error) {
	connection, err := listener.Listener.Accept()
	if err != nil {
		return nil, err
	}
	tracked := &trackedConnection{Conn: connection, owner: listener.owner}
	listener.owner.mu.Lock()
	defer listener.owner.mu.Unlock()
	if listener.owner.listener != listener.Listener {
		connection.Close()
		return nil, net.ErrClosed
	}
	listener.owner.connections[tracked] = true
	return tracked, nil
}

func (connection *trackedConnection) Close() error {
	connection.owner.mu.Lock()
	delete(connection.owner.connections, connection)
	connection.owner.mu.Unlock()
	return connection.Conn.Close()
}

func (proxy *Proxy) Start(address string, dial func(context.Context, string, string) (net.Conn, error)) error {
	proxy.mu.Lock()
	defer proxy.mu.Unlock()
	if proxy.listener != nil {
		return nil
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	proxy.listener = listener
	proxy.cancel = cancel
	proxy.connections = make(map[*trackedConnection]bool)
	server := socks5.Server{Dialer: func(request context.Context, network, address string) (net.Conn, error) {
		request, stop := context.WithCancel(request)
		defer stop()
		unlink := context.AfterFunc(ctx, stop)
		defer unlink()
		return dial(request, network, address)
	}, Logf: func(string, ...any) {}}
	go server.Serve(&trackingListener{Listener: listener, owner: proxy})
	return nil
}

func (proxy *Proxy) Stop() {
	proxy.mu.Lock()
	listener := proxy.listener
	proxy.listener = nil
	if proxy.cancel != nil {
		proxy.cancel()
		proxy.cancel = nil
	}
	connections := proxy.connections
	proxy.connections = nil
	proxy.mu.Unlock()
	if listener != nil {
		listener.Close()
	}
	for connection := range connections {
		connection.Close()
	}
}

func (proxy *Proxy) Active() bool {
	proxy.mu.Lock()
	defer proxy.mu.Unlock()
	return proxy.listener != nil
}
