package frpcembeddedclient

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/fatedier/frp/client"
	frpproxy "github.com/fatedier/frp/client/proxy"
	"github.com/fatedier/frp/pkg/config"
	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/config/v1/validation"
	"github.com/pelletier/go-toml/v2"
)

const maxConfigBytes = 1024 * 1024

type Prepared struct {
	service    *client.Service
	proxyNames []string
}

func Prepare(configText string) (*Prepared, error) {
	if strings.TrimSpace(configText) == "" {
		return nil, errors.New("frpc config is empty")
	}
	if len(configText) > maxConfigBytes {
		return nil, fmt.Errorf("frpc config exceeds %d bytes", maxConfigBytes)
	}
	if err := validateConfigBoundary(configText); err != nil {
		return nil, err
	}

	clientConfig := v1.ClientConfig{}
	if err := config.LoadConfigure([]byte(configText), &clientConfig); err != nil {
		return nil, fmt.Errorf("parse frpc TOML: %w", err)
	}
	common := &clientConfig.ClientCommonConfig
	if common.ServerAddr == "" || common.ServerPort < 1 || common.ServerPort > 65535 {
		return nil, errors.New("frpc config must specify serverAddr and a valid serverPort")
	}
	if common.Transport.Protocol != "" && common.Transport.Protocol != "tcp" {
		return nil, errors.New("embedded frpc supports only TCP control transport")
	}
	if len(clientConfig.Visitors) != 0 {
		return nil, errors.New("embedded frpc does not support visitor configs")
	}
	common.Complete()
	startNames := make(map[string]bool, len(common.Start))
	for _, name := range common.Start {
		startNames[name] = true
	}
	proxyConfigs := make([]v1.ProxyConfigurer, 0, len(clientConfig.Proxies))
	proxyNames := make([]string, 0, len(clientConfig.Proxies))
	for _, typedProxy := range clientConfig.Proxies {
		proxyConfig := typedProxy.ProxyConfigurer
		base := proxyConfig.GetBaseConfig()
		if len(startNames) != 0 && !startNames[base.Name] {
			continue
		}
		typeName := base.Type
		if typeName != "tcp" && typeName != "udp" {
			return nil, fmt.Errorf("embedded frpc supports only TCP/UDP proxies; got %q", typeName)
		}
		if base.Plugin.Type != "" {
			return nil, fmt.Errorf("embedded frpc does not support proxy plugins: %q", base.Name)
		}
		proxyConfig.Complete(common.User)
		proxyConfigs = append(proxyConfigs, proxyConfig)
		proxyNames = append(proxyNames, proxyConfig.GetBaseConfig().Name)
	}
	if len(proxyConfigs) == 0 {
		return nil, errors.New("frpc config must enable at least one TCP/UDP proxy")
	}
	if _, err := validation.ValidateAllClientConfig(common, proxyConfigs, nil); err != nil {
		return nil, fmt.Errorf("validate frpc config: %w", err)
	}
	service, err := client.NewService(common, proxyConfigs, nil, "")
	if err != nil {
		return nil, fmt.Errorf("initialize embedded frpc: %w", err)
	}
	return &Prepared{service: service, proxyNames: proxyNames}, nil
}

func (prepared *Prepared) ProxyCount() int {
	if prepared == nil {
		return 0
	}
	return len(prepared.proxyNames)
}

func (prepared *Prepared) Run(ctx context.Context) error {
	if prepared == nil || prepared.service == nil {
		return errors.New("embedded frpc is not prepared")
	}
	if ctx == nil {
		return errors.New("embedded frpc context is nil")
	}
	err := prepared.service.Run(ctx)
	if ctx.Err() != nil {
		return nil
	}
	return err
}

func (prepared *Prepared) ConnectedToFrps() bool {
	if prepared == nil || prepared.service == nil || len(prepared.proxyNames) == 0 {
		return false
	}
	controller := prepared.service.GetController()
	if controller == nil {
		return false
	}
	statuses := controller.GetAllProxyStatus()
	for _, name := range prepared.proxyNames {
		var status *frpproxy.WorkingStatus
		for _, candidate := range statuses {
			if candidate.Name == name {
				status = candidate
				break
			}
		}
		if status == nil || status.Phase != frpproxy.ProxyPhaseRunning || status.RemoteAddr == "" {
			return false
		}
	}
	return true
}

func validateConfigBoundary(configText string) error {
	var root map[string]any
	if err := toml.Unmarshal([]byte(configText), &root); err != nil {
		return fmt.Errorf("invalid frpc TOML: %w", err)
	}
	if err := rejectForbiddenConfigKeys(root); err != nil {
		return err
	}
	allowedRootKeys := map[string]struct{}{
		"version": {}, "auth": {}, "user": {}, "serverAddr": {}, "serverPort": {},
		"natHoleStunServer": {}, "dnsServer": {}, "loginFailExit": {}, "start": {},
		"log": {}, "webServer": {}, "transport": {}, "udpPacketSize": {},
		"metadatas": {}, "includes": {}, "proxies": {}, "visitors": {},
	}
	for key := range root {
		if _, allowed := allowedRootKeys[key]; !allowed {
			return fmt.Errorf("frpc config field %q is not supported by the embedded client", key)
		}
	}
	for _, key := range []string{"includes", "includeConfigFiles", "featureGates", "webServer", "virtualNet"} {
		if _, exists := root[key]; exists {
			return fmt.Errorf("frpc config field %q is not supported by the embedded client", key)
		}
	}
	if auth, ok := root["auth"].(map[string]any); ok {
		if _, exists := auth["tokenSource"]; exists {
			return errors.New("frpc auth.tokenSource is not supported")
		}
		if oidc, ok := auth["oidc"].(map[string]any); ok {
			if _, exists := oidc["tokenSource"]; exists {
				return errors.New("frpc auth.oidc.tokenSource is not supported")
			}
		}
	}
	if _, exists := root["serverAddr"]; !exists {
		return errors.New("frpc config must specify serverAddr")
	}
	if _, exists := root["serverPort"]; !exists {
		return errors.New("frpc config must specify serverPort")
	}
	return nil
}

func rejectForbiddenConfigKeys(value any) error {
	forbiddenKeys := map[string]struct{}{
		"includes": {}, "includeConfigFiles": {}, "featureGates": {},
		"webServer": {}, "virtualNet": {}, "tokenSource": {},
	}
	switch typed := value.(type) {
	case map[string]any:
		for key, nested := range typed {
			if _, forbidden := forbiddenKeys[key]; forbidden {
				return fmt.Errorf("frpc config field %q is not supported by the embedded client", key)
			}
			if err := rejectForbiddenConfigKeys(nested); err != nil {
				return err
			}
		}
	case []any:
		for _, nested := range typed {
			if err := rejectForbiddenConfigKeys(nested); err != nil {
				return err
			}
		}
	}
	return nil
}
