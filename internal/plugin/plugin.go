// Package plugin implements the SPIRE CredentialComposer plugin surface.
//
// Only ComposeWorkloadX509SVID is in scope. Every other hook returns
// codes.Unimplemented, which SPIRE treats as "leave this credential
// unchanged" — server CA, server SVID, agent SVID, and JWT behavior are
// intentionally untouched.
package plugin

import (
	"context"
	"net/url"
	"strings"
	"sync"

	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/hcl"
	credentialcomposerv1 "github.com/spiffe/spire-plugin-sdk/proto/spire/plugin/server/credentialcomposer/v1"
	configv1 "github.com/spiffe/spire-plugin-sdk/proto/spire/service/common/config/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Config is the plugin's HCL configuration. All fields are required; an
// incomplete configuration is rejected at Configure time so the server
// never runs with a partially specified policy.
type Config struct {
	// AllowedSPIFFEPrefixes restricts which workload SPIFFE IDs this
	// composer will shape. IDs outside every prefix fail closed.
	AllowedSPIFFEPrefixes []string `hcl:"allowed_spiffe_prefixes"`

	// MappingSnapshotPath points at the local SPIFFE-ID→AD-SID snapshot
	// (see internal/mapping). The plugin never queries a remote registry
	// on the issuance path.
	MappingSnapshotPath string `hcl:"mapping_snapshot_path"`

	// CDPURIs are the CRL Distribution Point URIs embedded in shaped
	// certificates (Gate 1).
	CDPURIs []string `hcl:"cdp_uris"`

	trustDomain string
}

type Plugin struct {
	credentialcomposerv1.UnsafeCredentialComposerServer
	configv1.UnimplementedConfigServer

	configMtx sync.RWMutex
	config    *Config
	logger    hclog.Logger
}

func New() *Plugin {
	return &Plugin{}
}

func (p *Plugin) SetLogger(logger hclog.Logger) {
	p.logger = logger
}

func (p *Plugin) Configure(ctx context.Context, req *configv1.ConfigureRequest) (*configv1.ConfigureResponse, error) {
	config := new(Config)
	config.trustDomain = req.CoreConfiguration.TrustDomain
	if err := hcl.Decode(config, req.HclConfiguration); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "failed to decode configuration: %v", err)
	}
	if err := validateConfig(config); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid configuration: %v", err)
	}
	p.setConfig(config)
	return &configv1.ConfigureResponse{}, nil
}

// validateConfig enforces the fail-closed configuration contract.
func validateConfig(c *Config) error {
	if c.trustDomain == "" {
		return errMissing("core trust domain")
	}
	if len(c.AllowedSPIFFEPrefixes) == 0 {
		return errMissing("allowed_spiffe_prefixes")
	}
	want := "spiffe://" + c.trustDomain + "/"
	for _, prefix := range c.AllowedSPIFFEPrefixes {
		if !strings.HasPrefix(prefix, want) {
			return status.Errorf(codes.InvalidArgument, "allowed_spiffe_prefixes entry %q is outside trust domain %q", prefix, c.trustDomain)
		}
	}
	if c.MappingSnapshotPath == "" {
		return errMissing("mapping_snapshot_path")
	}
	if len(c.CDPURIs) == 0 {
		return errMissing("cdp_uris")
	}
	for _, raw := range c.CDPURIs {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme == "" {
			return status.Errorf(codes.InvalidArgument, "cdp_uris entry %q is not a valid absolute URI", raw)
		}
		switch u.Scheme {
		case "http", "https", "ldap":
		default:
			return status.Errorf(codes.InvalidArgument, "cdp_uris entry %q has unsupported scheme %q", raw, u.Scheme)
		}
		if u.Host == "" {
			return status.Errorf(codes.InvalidArgument, "cdp_uris entry %q has no host", raw)
		}
	}
	return nil
}

func errMissing(field string) error {
	return status.Errorf(codes.InvalidArgument, "%s is required", field)
}

func (p *Plugin) ComposeServerX509CA(context.Context, *credentialcomposerv1.ComposeServerX509CARequest) (*credentialcomposerv1.ComposeServerX509CAResponse, error) {
	return nil, status.Error(codes.Unimplemented, "not implemented")
}

func (p *Plugin) ComposeServerX509SVID(context.Context, *credentialcomposerv1.ComposeServerX509SVIDRequest) (*credentialcomposerv1.ComposeServerX509SVIDResponse, error) {
	return nil, status.Error(codes.Unimplemented, "not implemented")
}

func (p *Plugin) ComposeAgentX509SVID(context.Context, *credentialcomposerv1.ComposeAgentX509SVIDRequest) (*credentialcomposerv1.ComposeAgentX509SVIDResponse, error) {
	return nil, status.Error(codes.Unimplemented, "not implemented")
}

func (p *Plugin) ComposeWorkloadX509SVID(context.Context, *credentialcomposerv1.ComposeWorkloadX509SVIDRequest) (*credentialcomposerv1.ComposeWorkloadX509SVIDResponse, error) {
	// Phase 2 implements this hook; until then the plugin must not be
	// deployed, since Unimplemented means SPIRE issues the SVID unshaped.
	return nil, status.Error(codes.Unimplemented, "ComposeWorkloadX509SVID is not implemented yet (phase 2)")
}

func (p *Plugin) ComposeWorkloadJWTSVID(context.Context, *credentialcomposerv1.ComposeWorkloadJWTSVIDRequest) (*credentialcomposerv1.ComposeWorkloadJWTSVIDResponse, error) {
	return nil, status.Error(codes.Unimplemented, "not implemented")
}

func (p *Plugin) setConfig(config *Config) {
	p.configMtx.Lock()
	p.config = config
	p.configMtx.Unlock()
}

func (p *Plugin) getConfig() (*Config, error) {
	p.configMtx.RLock()
	defer p.configMtx.RUnlock()
	if p.config == nil {
		return nil, status.Error(codes.FailedPrecondition, "not configured")
	}
	return p.config, nil
}
