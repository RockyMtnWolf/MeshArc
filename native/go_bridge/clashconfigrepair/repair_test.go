package clashconfigrepair

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestRepairMovesNodeAndPrioritizesRules(t *testing.T) {
	input := `# preserve root comment
proxies:
  - name: existing
    type: socks5
    server: example.invalid
    password: preserve-secret
proxy-groups:
  - name: select
    type: select
    proxies: [existing]
  - name: MeshArc-Tailnet
    type: socks5
    server: 127.0.0.1
    port: 1055
  - name: auto
    type: url-test
    include-all-proxies: true
    exclude-filter: old-pattern
rules:
  - IP-CIDR,100.64.0.0/10,DIRECT
  - IP-CIDR,100.64.0.0/10,MeshArc-Tailnet,no-resolve
  - MATCH,select
dns:
  enable: true
`
	repaired, err := Repair(input)
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Proxies []struct {
			Name     string `yaml:"name"`
			Password string `yaml:"password"`
		} `yaml:"proxies"`
		Groups []struct {
			Name    string `yaml:"name"`
			Exclude string `yaml:"exclude-filter"`
		} `yaml:"proxy-groups"`
		Rules []string `yaml:"rules"`
	}
	if err := yaml.Unmarshal([]byte(repaired), &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Proxies) != 2 || decoded.Proxies[0].Name != ProxyName || decoded.Proxies[1].Password != "preserve-secret" {
		t.Fatal("proxy relocation changed an unrelated proxy")
	}
	if len(decoded.Groups) != 2 || !strings.Contains(decoded.Groups[1].Exclude, "old-pattern") ||
		!strings.Contains(decoded.Groups[1].Exclude, "^MeshArc-Tailnet$") {
		t.Fatal("group relocation or automatic selection exclusion failed")
	}
	if len(decoded.Rules) != 4 || !strings.Contains(decoded.Rules[0], ProxyName) ||
		decoded.Rules[2] != "IP-CIDR,100.64.0.0/10,DIRECT" || decoded.Rules[3] != "MATCH,select" {
		t.Fatal("rule precedence or existing order changed")
	}
	if !strings.Contains(repaired, "# preserve root comment") || !strings.Contains(repaired, "dns:") {
		t.Fatal("unrelated configuration was removed")
	}
	second, err := Repair(repaired)
	if err != nil || second != repaired {
		t.Fatal("repair is not idempotent")
	}
}

func TestRepairRejectsUnsafeOrUnsupportedDocuments(t *testing.T) {
	for _, content := range []string{
		"", "[]", "proxies: [\n", "proxies: []\nproxies: []\n",
		"proxies: []\n---\nproxies: []\n", "proxies: {}\n",
		"proxy-groups:\n  - name: MeshArc-Tailnet\n    type: select\n    proxies: [DIRECT]\n",
	} {
		if _, err := Repair(content); err == nil {
			t.Fatal("unsupported input unexpectedly repaired")
		}
	}
}
