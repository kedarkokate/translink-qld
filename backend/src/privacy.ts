/**
 * Privacy policy served at /privacy.
 *
 * Plain HTML, no dependencies. The URL is referenced from the iOS app's
 * About sheet and from App Store Connect (Privacy Policy URL field).
 */
export const PRIVACY_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>TransitQLD Privacy Policy</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
         max-width: 720px; margin: 2rem auto; padding: 0 1.25rem;
         line-height: 1.55; color: #111; background: #fafafa; }
  h1 { font-size: 1.7rem; }
  h2 { font-size: 1.1rem; margin-top: 1.75rem; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.95em; }
  footer { margin-top: 3rem; font-size: 0.85rem; color: #555; }
  a { color: #0066cc; }
</style>
</head>
<body>
<h1>TransitQLD Privacy Policy</h1>
<p><em>Effective 15 May 2026.</em></p>
<p>This policy explains how the TransitQLD iOS app and its supporting backend
(a Cloudflare Worker at <code>translink-qld.transitqld.workers.dev</code>) handle data.</p>

<h2>What we collect</h2>
<ul>
  <li><strong>Approximate location</strong> — when you grant location permission, your device's
      coordinates are sent to the backend so we can return nearby transit stops and journey
      suggestions. Location is used only to answer the immediate request and is not stored.</li>
  <li><strong>Standard request data</strong> — our hosting provider Cloudflare records access logs
      (IP address, timestamp, requested URL) for abuse prevention and service security. We do not
      access or correlate these logs.</li>
</ul>

<h2>What we do not collect</h2>
<ul>
  <li>No user accounts. There is no sign-in.</li>
  <li>No cookies, tracking pixels, or third-party advertising.</li>
  <li>No analytics SDKs (no Firebase, Google Analytics, etc.).</li>
  <li>No data sharing with third parties for marketing.</li>
</ul>

<h2>Data sources</h2>
<p>Schedule and real-time transit data is sourced from
<a href="https://translink.com.au/about-translink/open-data">TransLink Open Data</a>,
published by the Queensland Department of Transport and Main Roads under CC-BY 4.0.
No personal data is sent to TransLink.</p>

<h2>Retention</h2>
<p>Your location is processed in memory to answer a single request and discarded. Cloudflare's
standard access logs are retained per Cloudflare's policies; we do not retain copies.</p>

<h2>Your choices</h2>
<p>You can revoke location permission for TransitQLD at any time in iOS Settings. The app will
continue to function but cannot show nearby results until permission is restored.</p>

<h2>Contact</h2>
<p>For questions about this policy, email <code>shoppersons@gmail.com</code>.</p>

<footer>
  <p>Last updated 15 May 2026.</p>
</footer>
</body>
</html>`;
