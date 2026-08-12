package plugin

import (
	"context"
	"strings"
	"testing"

	configv1 "github.com/spiffe/spire-plugin-sdk/proto/spire/service/common/config/v1"
)

const validHCL = `
allowed_spiffe_prefixes = ["spiffe://example.org/svc/db/"]
mapping_snapshot_path   = "/etc/spire/adpkinit/mapping.json"
cdp_uris                = ["http://crl.example.org/svid.crl"]
`

func TestConfigure(t *testing.T) {
	tests := []struct {
		name        string
		trustDomain string
		hcl         string
		wantErr     string
	}{
		{name: "valid", trustDomain: "example.org", hcl: validHCL},
		{name: "empty config", trustDomain: "example.org", hcl: ``, wantErr: "allowed_spiffe_prefixes is required"},
		{
			name:        "prefix outside trust domain",
			trustDomain: "example.org",
			hcl: `
allowed_spiffe_prefixes = ["spiffe://other.org/svc/"]
mapping_snapshot_path   = "/etc/spire/adpkinit/mapping.json"
cdp_uris                = ["http://crl.example.org/svid.crl"]
`,
			wantErr: "outside trust domain",
		},
		{
			name:        "missing snapshot path",
			trustDomain: "example.org",
			hcl: `
allowed_spiffe_prefixes = ["spiffe://example.org/svc/"]
cdp_uris                = ["http://crl.example.org/svid.crl"]
`,
			wantErr: "mapping_snapshot_path is required",
		},
		{
			name:        "missing cdp uris",
			trustDomain: "example.org",
			hcl: `
allowed_spiffe_prefixes = ["spiffe://example.org/svc/"]
mapping_snapshot_path   = "/etc/spire/adpkinit/mapping.json"
`,
			wantErr: "cdp_uris is required",
		},
		{
			name:        "cdp uri bad scheme",
			trustDomain: "example.org",
			hcl: `
allowed_spiffe_prefixes = ["spiffe://example.org/svc/"]
mapping_snapshot_path   = "/etc/spire/adpkinit/mapping.json"
cdp_uris                = ["file:///etc/passwd"]
`,
			wantErr: "unsupported scheme",
		},
		{
			name:        "cdp uri not absolute",
			trustDomain: "example.org",
			hcl: `
allowed_spiffe_prefixes = ["spiffe://example.org/svc/"]
mapping_snapshot_path   = "/etc/spire/adpkinit/mapping.json"
cdp_uris                = ["not a uri"]
`,
			wantErr: "not a valid absolute URI",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := New()
			_, err := p.Configure(context.Background(), &configv1.ConfigureRequest{
				CoreConfiguration: &configv1.CoreConfiguration{TrustDomain: tt.trustDomain},
				HclConfiguration:  tt.hcl,
			})
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("Configure() unexpected error: %v", err)
				}
				if _, err := p.getConfig(); err != nil {
					t.Fatalf("config not stored after successful Configure: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("Configure() error = %v, want containing %q", err, tt.wantErr)
			}
		})
	}
}

func TestUnconfiguredFailsClosed(t *testing.T) {
	if _, err := New().getConfig(); err == nil {
		t.Fatal("getConfig() on unconfigured plugin must error")
	}
}
