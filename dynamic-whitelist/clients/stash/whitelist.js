const TOKEN = 'change-me-client-token';
const DEVICE = 'stash';
const ENDPOINT = `https://wl.example.com/pulse/${TOKEN}?device=${DEVICE}&mode=fast`;

$httpClient.get({ url: ENDPOINT, timeout: 5 }, (error, response, data) => {
  if (error) {
    console.log(`dynamic whitelist failed: ${error}`);
  } else {
    console.log(`dynamic whitelist status=${response.status} body=${data || ''}`);
  }
  $done({});
});

