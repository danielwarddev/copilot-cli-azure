const assert = require('node:assert/strict');
const http = require('node:http');
const { spawn } = require('node:child_process');

const server = http.createServer((request, response) => {
  let body = '';
  request.on('data', chunk => { body += chunk; });
  request.on('end', () => {
    try {
      const payload = JSON.parse(body);
      assert.equal(payload.model, 'test-deployment');
      assert.equal(payload.reasoning?.effort, 'high');
      console.log(`Verified ${request.url}: model=${payload.model}, reasoning.effort=${payload.reasoning.effort}`);
      finish(0);
    } catch (error) {
      console.error(error.message);
      finish(1);
    }
    response.writeHead(503);
    response.end();
  });
});
let child;
let timer;
let finished = false;
function finish(code) {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  child?.kill();
  server.close();
  server.closeAllConnections();
  process.exitCode = code;
}
server.listen(0, '127.0.0.1', () => {
  const endpoint = `http://127.0.0.1:${server.address().port}`;
  child = spawn('bash', ['-c', 'exec copilot "$@"', 'copilot', '-p', 'Reply OK without tools.', '--reasoning-effort', 'high', '--disable-builtin-mcps'], {
    env: {
      ...process.env,
      COPILOT_PROVIDER_TYPE: 'azure',
      COPILOT_PROVIDER_BASE_URL: endpoint,
      COPILOT_PROVIDER_API_KEY: 'local-test-key',
      COPILOT_PROVIDER_BEARER_TOKEN: '',
      COPILOT_PROVIDER_API_KEY_COMMAND: '',
      COPILOT_PROVIDER_HEADERS: '',
      COPILOT_PROVIDER_WIRE_API: 'responses',
      COPILOT_PROVIDER_TRANSPORT: 'http',
      COPILOT_MODEL: 'test-deployment',
      COPILOT_PROVIDER_MODEL_ID: 'gpt-5.4',
      COPILOT_PROVIDER_WIRE_MODEL: 'test-deployment'
    },
    stdio: ['ignore', 'ignore', 'inherit']
  });
  child.on('error', error => { console.error(error.message); finish(1); });
  child.on('exit', () => {
    if (!finished) { console.error('CLI exited before sending a request.'); finish(1); }
  });
  timer = setTimeout(() => { console.error('No request within 30 seconds.'); finish(1); }, 30000);
});