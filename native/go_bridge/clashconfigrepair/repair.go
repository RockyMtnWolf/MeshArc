package clashconfigrepair

import (
	"bytes"
	"fmt"
	"io"
	"strings"

	"gopkg.in/yaml.v3"
)

const ProxyName = "MeshArc-Tailnet"
const MaxBytes = 2 * 1024 * 1024

func Repair(content string) (string, error) {
	if len(content) == 0 || len(content) > MaxBytes {
		return "", fmt.Errorf("configuration must contain 1 byte to 2 MiB")
	}
	decoder := yaml.NewDecoder(strings.NewReader(content))
	var document yaml.Node
	if err := decoder.Decode(&document); err != nil {
		return "", fmt.Errorf("invalid YAML configuration")
	}
	var extra yaml.Node
	if err := decoder.Decode(&extra); err != io.EOF {
		return "", fmt.Errorf("only one YAML document is supported")
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return "", fmt.Errorf("configuration root must be a YAML mapping")
	}
	root := document.Content[0]
	seen := make(map[string]bool)
	for index := 0; index < len(root.Content); index += 2 {
		key := root.Content[index].Value
		if seen[key] {
			return "", fmt.Errorf("duplicate root configuration key")
		}
		seen[key] = true
	}
	proxies, err := sequence(root, "proxies", true)
	if err != nil {
		return "", err
	}
	groups, err := sequence(root, "proxy-groups", false)
	if err != nil {
		return "", err
	}
	if groups != nil {
		remaining := make([]*yaml.Node, 0, len(groups.Content))
		for _, group := range groups.Content {
			if group.Kind != yaml.MappingNode {
				return "", fmt.Errorf("proxy group aliases require manual repair")
			}
			if value(group, "name") == ProxyName {
				if value(group, "type") != "socks5" {
					return "", fmt.Errorf("reserved MeshArc name conflicts with an existing proxy group")
				}
				continue
			}
			if value(group, "include-all-proxies") == "true" || value(group, "include-all") == "true" {
				exclusion := "^MeshArc-Tailnet$"
				if existing := value(group, "exclude-filter"); existing != "" && !strings.Contains(existing, exclusion) {
					exclusion = "(?:" + existing + ")|(?:" + exclusion + ")"
				} else if existing != "" {
					exclusion = existing
				}
				put(group, "exclude-filter", scalar(exclusion))
			}
			remaining = append(remaining, group)
		}
		groups.Content = remaining
	}
	remaining := make([]*yaml.Node, 0, len(proxies.Content)+1)
	for _, proxy := range proxies.Content {
		if proxy.Kind != yaml.MappingNode {
			return "", fmt.Errorf("proxy aliases require manual repair")
		}
		if value(proxy, "name") != ProxyName {
			remaining = append(remaining, proxy)
		}
	}
	mesh := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	put(mesh, "name", scalar(ProxyName))
	put(mesh, "type", scalar("socks5"))
	put(mesh, "server", scalar("127.0.0.1"))
	put(mesh, "port", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!int", Value: "1055"})
	put(mesh, "udp", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"})
	proxies.Content = append([]*yaml.Node{mesh}, remaining...)
	rules, err := sequence(root, "rules", true)
	if err != nil {
		return "", err
	}
	remainingRules := make([]*yaml.Node, 0, len(rules.Content)+2)
	remainingRules = append(remainingRules,
		scalar("IP-CIDR,100.64.0.0/10,"+ProxyName+",no-resolve"),
		scalar("IP-CIDR6,fd7a:115c:a1e0::/48,"+ProxyName+",no-resolve"))
	for _, rule := range rules.Content {
		if rule.Kind != yaml.ScalarNode {
			return "", fmt.Errorf("rules must be plain strings for automatic repair")
		}
		fields := strings.Split(rule.Value, ",")
		if len(fields) >= 3 && strings.TrimSpace(fields[2]) == ProxyName &&
			((strings.TrimSpace(fields[0]) == "IP-CIDR" && strings.TrimSpace(fields[1]) == "100.64.0.0/10") ||
				(strings.TrimSpace(fields[0]) == "IP-CIDR6" && strings.TrimSpace(fields[1]) == "fd7a:115c:a1e0::/48")) {
			continue
		}
		remainingRules = append(remainingRules, rule)
	}
	rules.Content = remainingRules
	var buffer bytes.Buffer
	encoder := yaml.NewEncoder(&buffer)
	encoder.SetIndent(2)
	if err := encoder.Encode(&document); err != nil {
		return "", fmt.Errorf("unable to export repaired YAML")
	}
	if err := encoder.Close(); err != nil {
		return "", err
	}
	return buffer.String(), nil
}

func scalar(content string) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: content}
}

func value(mapping *yaml.Node, key string) string {
	for index := 0; index+1 < len(mapping.Content); index += 2 {
		if mapping.Content[index].Value == key {
			return mapping.Content[index+1].Value
		}
	}
	return ""
}

func put(mapping *yaml.Node, key string, content *yaml.Node) {
	for index := 0; index+1 < len(mapping.Content); index += 2 {
		if mapping.Content[index].Value == key {
			mapping.Content[index+1] = content
			return
		}
	}
	mapping.Content = append(mapping.Content, scalar(key), content)
}

func sequence(root *yaml.Node, key string, create bool) (*yaml.Node, error) {
	for index := 0; index+1 < len(root.Content); index += 2 {
		if root.Content[index].Value == key {
			section := root.Content[index+1]
			if section.Kind != yaml.SequenceNode {
				return nil, fmt.Errorf("%s must be a YAML list; aliases need manual repair", key)
			}
			return section, nil
		}
	}
	if !create {
		return nil, nil
	}
	section := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
	put(root, key, section)
	return section, nil
}
