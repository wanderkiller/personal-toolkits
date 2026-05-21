// ad-cleaner.js
const headers = $response.headers || {};
let ct = '';
for (const k in headers) {
  if (k.toLowerCase() === 'content-type') { ct = headers[k]; break; }
}

if (!ct.includes('text/html')) {
  $done({});
} else {
  let body = $response.body;

  if (body && typeof body === 'string') {
    const css = `<style id="ad-cleaner-wsj">
[data-testid="ad-container"],
[data-testid="ad-block"],
[data-testid="ad-container-label"],
.ad-portal,
.adWrapper,
[id^="wrapper-AD_"],
[id^="wrapper-MOBILE_"],
[id^="wrapper-wsj-body-AD_"],
.uds-ad-container,
.uds-ad-stack,
.body-ad-label,
.adContainer,
[class*="ad-portal"],
[class*="Ad-Container"] {
  display: none !important;
  height: 0 !important;
  min-height: 0 !important;
  max-height: 0 !important;
  margin: 0 !important;
  padding: 0 !important;
  border: 0 !important;
  visibility: hidden !important;
}
</style>`;

    const observerScript = `<script>
(function() {
  var killSelectors = '[data-testid="ad-container"],[data-testid="ad-block"],.ad-portal,.adWrapper,[id^="wrapper-AD_"],[id^="wrapper-MOBILE_"],[id^="wrapper-wsj-body-AD_"],.uds-ad-container';
  function kill() {
    document.querySelectorAll(killSelectors).forEach(function(el) { el.remove(); });
  }
  if (document.readyState !== 'loading') kill();
  else document.addEventListener('DOMContentLoaded', kill);
  new MutationObserver(kill).observe(document.documentElement, { childList: true, subtree: true });
})();
</script>`;

    if (body.includes('</head>')) {
      body = body.replace('</head>', css + observerScript + '</head>');
    } else {
      body = body.replace(/<body([^>]*)>/i, '<body$1>' + css + observerScript);
    }
  }

  $done({ body });
}
