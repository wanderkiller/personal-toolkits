const TOKEN = 'change-me-client-token';
const DEVICE = 'quantumult-x';
const url = `https://wl.example.com/pulse/${TOKEN}?device=${DEVICE}&mode=fast`;

$task.fetch({ url, method: 'GET' }).then(
  response => {
    console.log(`dynamic whitelist status=${response.statusCode} body=${response.body || ''}`);
    $done();
  },
  reason => {
    console.log(`dynamic whitelist failed: ${reason.error || reason}`);
    $done();
  }
);

