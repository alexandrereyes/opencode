## Custom plugin ownership

- This package owns feature-specific custom backend policy. Keep custom capabilities modular here and consume public plugin APIs before changing shared backend packages.
- When existing plugin APIs are insufficient, add the smallest reusable extension point at the required backend boundary, then keep the feature-specific behavior in this package.
- Use dedicated backend aggregation only when a plugin extension point cannot preserve the required behavior or runtime guarantees. Reuse native services, transactions, and lifecycle; do not copy upstream implementation bodies.
- Keep unavoidable shared-backend integration points small, localized, documented, and covered by meaningful parity tests against the current upstream baseline.
