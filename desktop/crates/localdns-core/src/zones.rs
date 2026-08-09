//! Zone derivation, shared by every resolver backend.
//! Port of `ResolverSetup.desiredZones` (the pure part of ResolverSetup.swift).

use std::collections::BTreeSet;

use crate::rules::DnsRule;

/// Zones to register for the given rules: every enabled rule contributes its
/// normalized pattern minus a leading "*.". An exact rule "host.test" therefore
/// registers zone "host.test" — which also routes subdomains of host.test to
/// us (acceptable: unmatched names simply get NXDOMAIN/NODATA like any other).
pub fn desired_zones(rules: &[DnsRule]) -> BTreeSet<String> {
    rules
        .iter()
        .filter(|rule| rule.enabled)
        .filter_map(|rule| {
            let pattern = rule.normalized_pattern();
            let zone = pattern.strip_prefix("*.").unwrap_or(&pattern);
            if zone.is_empty() {
                None
            } else {
                Some(zone.to_string())
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desired_zones_strips_wildcard_and_skips_disabled() {
        let rules = vec![
            DnsRule::new("*.myapp.test"),
            DnsRule::new("host.other.test"),
            DnsRule {
                enabled: false,
                ..DnsRule::new("*.disabled.test")
            },
            DnsRule::new("*.MyApp.Test."), // duplicate after normalization
        ];
        let zones: Vec<String> = desired_zones(&rules).into_iter().collect();
        assert_eq!(zones, vec!["host.other.test", "myapp.test"]);
    }
}
