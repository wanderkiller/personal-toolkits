// ad-cleaner.js
// 适用 www.wsj.com 和 cn.wsj.com
// 兼容 Quantumult X 和 Stash

const headers = $response.headers || {};
let ct = '';
for (const k in headers) {
  if (k.toLowerCase() === 'content-type') {
    ct = headers[k];
    break;
  }
}

if (!ct.includes('text/html')) {
  $done({});
} else {
  let body = $response.body;

  if (body && typeof body === 'string') {
    const css = `<style id="ad-cleaner-wsj">
[data-testid="ad-container"],
.ad-portal,
.adWrapper,
[id^="wrapper-AD_"],
[id^="wrapper-MOBILE_"],
.uds-ad-container,
.uds-ad-stack,
.body-ad-label {
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

    if (body.includes('</head>')) {
      body = body.replace('</head>', css + '</head>');
    } else {
      body = body.replace(/<body([^>]*)>/i, `<body$1>${css}`);
    }
  }

  $done({ body });
}
