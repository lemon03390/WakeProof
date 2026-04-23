// WakeProof Claude Proxy — Cloudflare Worker
//
// Forwards POST /v1/messages to api.anthropic.com/v1/messages so the iOS app
// doesn't hit Cloudflare's edge bot-detection on api.anthropic.com directly.
// Server-to-server traffic from a Worker to Anthropic sails through without
// the fingerprint scoring that blocks URLSession client calls from iPhones.
//
// Auth: the iOS client continues to send the Anthropic API key in x-api-key;
// the Worker forwards it as-is. For the hackathon this keeps Secrets.swift as
// the single place the key lives. Post-hackathon improvement: move the key to
// `wrangler secret put ANTHROPIC_API_KEY` and drop the header forwarding so
// the key lives only server-side.
//
// Supported paths: only POST /v1/messages. Anything else returns 404.

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (request.method !== 'POST' || url.pathname !== '/v1/messages') {
      return new Response('Not found', { status: 404 });
    }

    const apiKey = request.headers.get('x-api-key');
    if (!apiKey) {
      return new Response(
        JSON.stringify({ error: { type: 'unauthorized', message: 'Missing x-api-key header' } }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      );
    }

    const anthropicVersion = request.headers.get('anthropic-version') || '2023-06-01';
    const body = await request.arrayBuffer();

    let upstream;
    try {
      upstream = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': anthropicVersion,
        },
        body,
      });
    } catch (err) {
      return new Response(
        JSON.stringify({ error: { type: 'upstream_fetch_failed', message: String(err) } }),
        { status: 502, headers: { 'Content-Type': 'application/json' } }
      );
    }

    const responseBody = await upstream.arrayBuffer();
    const responseHeaders = new Headers();
    responseHeaders.set(
      'Content-Type',
      upstream.headers.get('Content-Type') || 'application/json'
    );
    // Forward a few useful debug/metadata headers so the iOS logger can still
    // capture request_id and rate-limit state if Anthropic returns them.
    for (const key of [
      'request-id',
      'x-request-id',
      'anthropic-ratelimit-requests-remaining',
      'anthropic-ratelimit-tokens-remaining',
    ]) {
      const value = upstream.headers.get(key);
      if (value) responseHeaders.set(key, value);
    }

    return new Response(responseBody, {
      status: upstream.status,
      headers: responseHeaders,
    });
  },
};
