const assert = require('node:assert/strict');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');

const header = 'model_key,aliases,input_per_1m,cached_input_per_1m,cache_write_per_1m,output_per_1m';
const csv = `${header},base_model,reasoning_efforts\nreasoner,,1,0,0,2,gpt-5.4,low|medium|high\nplain,,1,0,0,2,,\n`;
const quote = text => `'${text.replaceAll("'", "'\\''")}'`;
const cases = [
  { name: 'starting effort', keys: [], effort: 'medium' },
  { name: 'right', keys: [39], effort: 'high' },
  { name: 'narrow terminal', keys: [39], effort: 'high', width: 30 },
  { name: 'left wraps', keys: [37, 37], effort: 'high' },
  { name: 'right wraps', keys: [39, 39], effort: 'low' },
  { name: 'row memory', keys: [39, 40, 39, 38], effort: 'high' },
  { name: 'configured default', keys: [], effort: 'low', csv: csv.replace('reasoning_efforts\n', 'reasoning_efforts,default_reasoning_effort\n').replace('low|medium|high\n', 'low|medium|high,low\n') },
  { name: 'none selectable', keys: [39, 39], effort: 'none', csv: csv.replace('low|medium|high', 'none|low|medium|high') },
  { name: 'none only', keys: [39, 37], effort: 'none', csv: csv.replace('low|medium|high', 'none') },
  { name: 'none default', keys: [], effort: 'none', csv: csv.replace('reasoning_efforts\n', 'reasoning_efforts,default_reasoning_effort\n').replace('low|medium|high\n', 'none|low|medium|high,none\n') },
  { name: 'single effort', keys: [39, 37], effort: 'high', csv: csv.replace('low|medium|high', 'high') },
  { name: 'unsupported row', keys: [40, 39, 37], effort: null, model: 'plain' },
  { name: 'old CSV', keys: [39], effort: null, csv: `${header}\nreasoner,,1,0,0,2\n` },
  { name: 'direct args', keys: [], effort: 'high', args: ['reasoner', '--reasoning-effort', 'high'] },
  { name: 'picker resume', keys: [], effort: 'medium', args: ['--resume=test-session'], handoffArgs: ['--reasoning-effort', 'medium', '--resume=test-session'] },
  { name: 'picker quoted args', keys: [], effort: 'medium', args: ['--resume', 'session with spaces'], handoffArgs: ['--reasoning-effort', 'medium', '--resume', 'session with spaces'] },
  { name: 'picker plain resume', keys: [40], effort: null, model: 'plain', args: ['--resume=test-session'], handoffArgs: ['--resume=test-session'] },
  { name: 'picker explicit effort', keys: [], effort: 'high', args: ['--resume=test-session', '--reasoning-effort', 'high'], handoffArgs: ['--resume=test-session', '--reasoning-effort', 'high'] },
  { name: 'picker equals effort', keys: [], effort: 'high', args: ['--reasoning-effort=high'], handoffArgs: ['--reasoning-effort=high'] },
  { name: 'invalid metadata', keys: [], invalid: true, csv: csv.replace('low|medium|high', 'bogus') },
  { name: 'invalid default', keys: [], invalid: true, csv: csv.replace('reasoning_efforts\n', 'reasoning_efforts,default_reasoning_effort\n').replace('low|medium|high\n', 'low|medium|high,max\n') }
];
for (const shell of ['bash', 'powershell']) {
  for (const test of cases) {
    const fixture = test.csv ?? csv;
    let result;
    if (shell === 'bash') {
      let source = fs.readFileSync('copilot-azure/caz', 'utf8').replaceAll('\r\n', '\n');
      source = source.replace(/^\[\[ -f "\$pricing_file" \]\].*$/m, ':')
        .replace(/done < "\$pricing_file"/, `done < <(printf '%s' ${quote(fixture)})`)
        .replace(/^[ \t]*\[\[ -t 0 && -t 2 \]\].*$/m, '  :')
        .replace(/^[ \t]*terminal_width=.*$/m, `  terminal_width=${test.width ?? 120}`)
        .replace(/^exec copilot .*$/m, 'printf "HANDOFF model=%s base=%s wire=%s args=%s\\n" "$COPILOT_MODEL" "$COPILOT_PROVIDER_MODEL_ID" "$COPILOT_PROVIDER_WIRE_MODEL" "$*"');
      const sequences = { 37: '\x1b[D', 38: '\x1b[A', 39: '\x1b[C', 40: '\x1b[B' };
      result = spawnSync('bash', ['-c', 'eval "$PICKER_TEST_SOURCE"', 'caz', ...(test.args ?? [])], {
        input: test.keys.map(key => sequences[key]).join('') + '\r',
        env: { ...process.env, COPILOT_PROVIDER_API_KEY: 'local-test-key', PICKER_TEST_SOURCE: source },
        encoding: 'utf8', timeout: 15000
      });
    } else {
      let source = fs.readFileSync('copilot-azure/caz.ps1', 'utf8');
      source = source.replace(/^\$pricingPath =.*$/m, "$pricingPath = 'unused'")
        .replace(/if \(-not \(Test-Path \$pricingPath\)\)/, 'if ($false)')
        .replace(/Import-Csv \$pricingPath/, `('${fixture.replaceAll("'", "''")}' | ConvertFrom-Csv)`)
        .replace(/\[Console\]::IsInputRedirected/, '$false')
        .replace(/\$Host.UI.RawUI.WindowSize.Width/, String(test.width ?? 120))
        .replace(/\$Host.UI.RawUI.ReadKey\('NoEcho,IncludeKeyDown'\)/, '[pscustomobject]@{ VirtualKeyCode = $keyQueue.Dequeue() }');
      const command = `$env:COPILOT_PROVIDER_API_KEY='local-test-key'; $keyQueue=New-Object 'System.Collections.Generic.Queue[int]'; ${[...test.keys, 13].map(key => `$keyQueue.Enqueue(${key});`).join(' ')}
function copilot { Write-Output ('HANDOFF model={0} base={1} wire={2} args={3}' -f $env:COPILOT_MODEL,$env:COPILOT_PROVIDER_MODEL_ID,$env:COPILOT_PROVIDER_WIRE_MODEL,($args -join ' ')); $global:LASTEXITCODE=0 }
& ([scriptblock]::Create('${source.replaceAll("'", "''")}')) ${ (test.args ?? []).map(arg => `'${arg}'`).join(' ') }`;
      result = spawnSync('powershell.exe', ['-NoProfile', '-EncodedCommand', Buffer.from(command, 'utf16le').toString('base64')], {
        encoding: 'utf8', timeout: 15000
      });
    }
    assert.ifError(result.error);
    const output = result.stdout + result.stderr;
    if (test.invalid) {
      assert.notEqual(result.status, 0, `${shell}: ${test.name}`);
      assert.match(output, /Invalid (default )?reasoning effort/, `${shell}: ${test.name}`);
    } else {
      assert.equal(result.status, 0, `${shell}: ${test.name}\n${output}`);
      const model = test.model ?? 'reasoner';
      const selectedRow = fixture.trim().split('\n').slice(1).find(row => row.split(',')[0] === model).split(',');
      const base = selectedRow[6] || model;
      const args = test.handoffArgs ? test.handoffArgs.join(' ') : test.effort ? `--reasoning-effort ${test.effort}` : '';
      const handoff = output.split(/\r?\n/).find(line => line.startsWith('HANDOFF '));
      assert.equal(handoff, `HANDOFF model=${model} base=${base} wire=${model} args=${args}`, `${shell}: ${test.name}\n${output}`);
      if (test.effort && !test.args) assert.ok(output.includes(`[${test.effort}]`), `${shell}: visible effort`);
      if (!test.args) {
        assert.ok(!output.includes('[default]'), `${shell}: no placeholder efforts`);
        if (!test.effort) assert.ok(output.includes(`${model} [N/A]`), `${shell}: unavailable effort`);
        if (!test.width) assert.ok(output.includes('model [effort]'), `${shell}: column heading`);
      }
      if (test.width) assert.ok(!output.includes('Costs are in USD'), `${shell}: hidden prices`);
    }
    console.log(`Passed ${shell}: ${test.name}`);
  }
}