// Package encoding will hold the phase-1 DER builders for the two target
// extensions. Nothing may be implemented here until known-good fixtures
// exist (a real ADCS-issued certificate or an authoritative Microsoft test
// vector): the exact bytes the target KDC accepts must be pinned by golden
// tests, not inferred from documentation. Builders also require
// malformed-input, duplicate-extension, and fuzz tests before the plugin
// may call them.
package encoding

import "encoding/asn1"

var (
	// OIDCRLDistributionPoints is id-ce-cRLDistributionPoints (RFC 5280 §4.2.1.13).
	OIDCRLDistributionPoints = asn1.ObjectIdentifier{2, 5, 29, 31}

	// OIDNTDSCASecurityExt is szOID_NTDS_CA_SECURITY_EXT, the AD SID
	// security extension consumed by KDC strong certificate mapping.
	OIDNTDSCASecurityExt = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 311, 25, 2}

	// OIDNTDSObjectSID is szOID_NTDS_OBJECTSID, the inner OtherName type
	// carrying the account SID inside the security extension.
	OIDNTDSObjectSID = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 311, 25, 2, 1}
)
