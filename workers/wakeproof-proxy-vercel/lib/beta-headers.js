// WakeProof Claude Proxy — shared Anthropic beta-header constants.
//
// P4 (Stage 6 Wave 1): the cron cleanup handler and the wildcard route
// both need to identify the current Managed Agents beta identifier.
// Duplicating the literal string across two files meant a beta bump
// required remembering to edit both — a footgun for future maintainers
// who only grep the file they're editing. Single source of truth here.
//
// When Anthropic publishes a new beta (or retires this one):
//   1. Update `CURRENT_BETA` below.
//   2. If a transition period needs to forward BOTH old + new, add the
//      old token to `ALLOWED_BETA_HEADERS` alongside `CURRENT_BETA`.
//   3. Otherwise the set stays a single-element superset of `CURRENT_BETA`.
//
// Not used by api/v1/messages.js — that handler does not forward a beta
// header (the vision verification path does not use Managed Agents).

export const CURRENT_BETA = 'managed-agents-2026-04-01';

/**
 * Allowlist of beta header tokens the proxy will forward upstream.
 * Unknown tokens are dropped with an info log so we can spot
 * misconfigured clients without silently enabling them. Keep
 * `CURRENT_BETA` always in the set; add historical tokens only during
 * an explicit cross-version transition.
 */
export const ALLOWED_BETA_HEADERS = new Set([
  CURRENT_BETA,
]);
