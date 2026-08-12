package main

import (
	"github.com/scootscootscootscoot/spire-credentialcomposer-adpkinit/internal/plugin"
	"github.com/spiffe/spire-plugin-sdk/pluginmain"
	credentialcomposerv1 "github.com/spiffe/spire-plugin-sdk/proto/spire/plugin/server/credentialcomposer/v1"
	configv1 "github.com/spiffe/spire-plugin-sdk/proto/spire/service/common/config/v1"
)

func main() {
	p := plugin.New()
	pluginmain.Serve(
		credentialcomposerv1.CredentialComposerPluginServer(p),
		configv1.ConfigServiceServer(p),
	)
}
