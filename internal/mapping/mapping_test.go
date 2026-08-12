package mapping

import "testing"

func TestValidateSIDString(t *testing.T) {
	valid := []string{
		"S-1-5-18",
		"S-1-5-21-3623811015-3361044348-30300820-1013",
		"S-1-5-21-0-0-0-4294967295",
	}
	for _, s := range valid {
		if err := ValidateSIDString(s); err != nil {
			t.Errorf("ValidateSIDString(%q) = %v, want nil", s, err)
		}
	}

	invalid := map[string]string{
		"":                         "empty string",
		"S-1-5":                    "no sub-authority",
		"s-1-5-18":                 "lowercase s",
		"S-2-5-18":                 "revision 2",
		"S-1-5-18-":                "trailing dash",
		"S-1-5--18":                "empty component",
		"S-1-5-018":                "leading zero",
		"S-1-5-4294967296":         "sub-authority overflows uint32",
		"S-1-281474976710656-5-18": "authority overflows 48 bits",
		"S-1-0x5-18":               "hex authority",
		"S-1-5-21-abc":             "non-numeric",
		"S-1-5- 18":                "embedded space",
		"S-1-5-21-1-2-3-4-5-6-7-8-9-10-11-12-13-14-15-16": "16 sub-authorities",
	}
	for s, why := range invalid {
		if err := ValidateSIDString(s); err == nil {
			t.Errorf("ValidateSIDString(%q) = nil, want error (%s)", s, why)
		}
	}
}
