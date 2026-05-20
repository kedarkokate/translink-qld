/**
 * Support page served at /support. The URL is the one we hand to Apple
 * in App Store Connect's Support URL field, so it has to clearly tell a
 * user how to reach the developer with questions or bug reports.
 *
 * Kept plain HTML / no dependencies, same shape as the privacy page.
 */
export const SUPPORT_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>TransitQLD Support</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
         max-width: 720px; margin: 2rem auto; padding: 0 1.25rem;
         line-height: 1.55; color: #111; background: #fafafa; }
  h1 { font-size: 1.7rem; }
  h2 { font-size: 1.1rem; margin-top: 1.75rem; }
  ul { padding-left: 1.25rem; }
  li { margin: 0.35rem 0; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.95em; }
  .contact { padding: 1rem; background: #fff; border: 1px solid #e3e3e3;
             border-radius: 8px; margin-top: 0.75rem; }
  footer { margin-top: 3rem; font-size: 0.85rem; color: #555; }
  a { color: #0066cc; }
</style>
</head>
<body>
<h1>TransitQLD Support</h1>
<p>TransitQLD is an iOS app showing live nearby stops, departures and
journey planning for the TransLink South-East Queensland transit network
(buses, trains and ferries).</p>

<h2>Need help?</h2>
<div class="contact">
  Email <a href="mailto:shoppersons@gmail.com"><code>shoppersons@gmail.com</code></a>
  with a description of what you were doing, what you expected to happen,
  and what actually happened. Screenshots help.
</div>

<h2>Frequently asked</h2>
<ul>
  <li><strong>Why is nothing showing on the map?</strong> The app needs location
      permission. iOS Settings → Privacy &amp; Security → Location Services →
      TransitQLD → While Using.</li>
  <li><strong>Why does "No TransLink stops in this area" appear?</strong>
      TransitQLD covers South-East Queensland — Brisbane, Logan, Ipswich,
      Gold Coast, Sunshine Coast and the Hinterland. Regions outside SEQ
      (Rockhampton, Toowoomba, etc.) are served by other operators whose
      data isn't in this feed.</li>
  <li><strong>Why is a departure missing or late?</strong> The app merges the
      TransLink scheduled timetable with realtime delays from TransLink's
      live feed. If a real-world bus deviates beyond what TransLink
      publishes, we don't see it. Open the TransLink website's
      <code>Service notices</code> for live disruptions.</li>
  <li><strong>How do I report a bad route suggestion in Directions?</strong>
      Email the From / To you searched and the time, and we can usually
      reproduce it.</li>
</ul>

<h2>Other links</h2>
<ul>
  <li><a href="/privacy">Privacy policy</a></li>
  <li><a href="https://translink.com.au/about-translink/open-data">TransLink Open Data</a> — the data source TransitQLD uses (CC-BY 4.0).</li>
</ul>

<footer>
  <p>Last updated 21 May 2026.</p>
</footer>
</body>
</html>`;
