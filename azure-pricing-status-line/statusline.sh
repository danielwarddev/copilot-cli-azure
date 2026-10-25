#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
json_input="$(cat)"
JSON_INPUT="$json_input" node - "$script_dir" <<'NODE'
const fs = require('fs');
const path = require('path');

const scriptDir = process.argv[2];

function readJsonFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

function writeJsonFile(filePath, value) {
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2));
}

function parseCsvLine(line) {
  const values = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    const next = line[i + 1];

    if (char === '"' && inQuotes && next === '"') {
      current += '"';
      i += 1;
    } else if (char === '"') {
      inQuotes = !inQuotes;
    } else if (char === ',' && !inQuotes) {
      values.push(current);
      current = '';
    } else {
      current += char;
    }
  }

  values.push(current);
  return values;
}

function parsePricingCsv(csv) {
  const lines = csv.trim().split(/\r?\n/).filter(Boolean);
  const headers = parseCsvLine(lines[0]);

  return lines.slice(1).map((line) => {
    const values = parseCsvLine(line);
    return Object.fromEntries(headers.map((header, index) => [header, values[index] ?? '']));
  });
}

function getNumber(value) {
  const number = Number(value ?? 0);
  return Number.isFinite(number) ? number : 0;
}

function createUsageSnapshot(usage) {
  return {
    input_tokens: getNumber(usage?.input_tokens),
    output_tokens: getNumber(usage?.output_tokens),
    cache_creation_input_tokens: getNumber(usage?.cache_creation_input_tokens),
    cache_read_input_tokens: getNumber(usage?.cache_read_input_tokens),
  };
}

function isSameUsage(left, right) {
  return left.input_tokens === right.input_tokens
    && left.output_tokens === right.output_tokens
    && left.cache_creation_input_tokens === right.cache_creation_input_tokens
    && left.cache_read_input_tokens === right.cache_read_input_tokens;
}

function hasUsage(usage) {
  return Object.values(usage).some((value) => value > 0);
}

function calculateUsageDelta(current, previous) {
  return {
    input_tokens: Math.max(0, current.input_tokens - previous.input_tokens),
    output_tokens: Math.max(0, current.output_tokens - previous.output_tokens),
    cache_creation_input_tokens: Math.max(0, current.cache_creation_input_tokens - previous.cache_creation_input_tokens),
    cache_read_input_tokens: Math.max(0, current.cache_read_input_tokens - previous.cache_read_input_tokens),
  };
}

function calculateCost(usage, pricing) {
  const inputTokens = getNumber(usage.input_tokens);
  const outputTokens = getNumber(usage.output_tokens);
  const cacheReadInputTokens = getNumber(usage.cache_read_input_tokens);
  const cacheWriteInputTokens = getNumber(usage.cache_creation_input_tokens);
  let nonCachedInputTokens = inputTokens - cacheReadInputTokens;

  if (nonCachedInputTokens < 0) {
    throw new Error('cache_read_input_tokens cannot exceed input_tokens.');
  }

  // Cache writes are reported inside input_tokens. Only reclassify them when the model
  // actually has a separate write rate (gpt-5.6+); otherwise they bill as normal input.
  const cacheWriteRate = getNumber(pricing.cache_write_per_1m);
  let billedCacheWriteTokens = 0;
  if (cacheWriteRate > 0) {
    billedCacheWriteTokens = Math.min(cacheWriteInputTokens, nonCachedInputTokens);
    nonCachedInputTokens -= billedCacheWriteTokens;
  }

  const inputCost = nonCachedInputTokens / 1_000_000 * getNumber(pricing.input_per_1m);
  const cachedInputCost = cacheReadInputTokens / 1_000_000 * getNumber(pricing.cached_input_per_1m);
  const cacheWriteCost = billedCacheWriteTokens / 1_000_000 * cacheWriteRate;
  const outputCost = outputTokens / 1_000_000 * getNumber(pricing.output_per_1m);
  return inputCost + cachedInputCost + cacheWriteCost + outputCost;
}

function findPricing(status) {
  const pricingPath = path.join(scriptDir, 'foundry-model-pricing.csv');
  if (!fs.existsSync(pricingPath)) {
    return null;
  }

  const modelId = status.model?.id ?? '';
  const modelDisplayName = status.model?.display_name ?? '';
  const searchText = `${modelId} ${modelDisplayName}`.toLowerCase();
  const pricingRows = parsePricingCsv(fs.readFileSync(pricingPath, 'utf8'));

  return pricingRows.find((row) => {
    // Match against model_key plus any pipe-separated aliases. Aliases may be empty.
    const candidates = [row.model_key, ...(row.aliases ?? '').split('|')];
    return candidates
      .map((candidate) => candidate.trim().toLowerCase())
      .filter(Boolean)
      .some((candidate) => searchText.includes(candidate));
  }) ?? null;
}

function getTranscriptEventsPath(transcriptPath) {
  // Copilot passes the session-state directory as transcript_path; its events.jsonl holds the event log.
  if (!transcriptPath) {
    return null;
  }
  try {
    const eventsPath = fs.statSync(transcriptPath).isDirectory() ? path.join(transcriptPath, 'events.jsonl') : transcriptPath;
    return fs.statSync(eventsPath).isFile() ? eventsPath : null;
  } catch {
    return null;
  }
}

function findNewUserPrompt(eventsPath, offset) {
  // Scan only the bytes appended since the last refresh, stopping at the last complete line.
  const fd = fs.openSync(eventsPath, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const start = offset >= 0 && offset <= size ? offset : 0;
    const buffer = Buffer.alloc(size - start);
    let read = 0;
    while (read < buffer.length) {
      const count = fs.readSync(fd, buffer, read, buffer.length - read, start + read);
      if (count <= 0) {
        break;
      }
      read += count;
    }

    const lastNewline = buffer.lastIndexOf(10, read - 1);
    if (read === 0 || lastNewline < 0) {
      return { hasNewPrompt: false, offset: start };
    }

    const text = buffer.toString('utf8', 0, lastNewline + 1);
    return {
      hasNewPrompt: /^\{"type":"user\.message"/m.test(text),
      offset: start + lastNewline + 1,
    };
  } finally {
    fs.closeSync(fd);
  }
}

function updateSessionUsage(sessionId, currentUsage, transcriptPath) {
  const safeSessionId = (sessionId || 'unknown').replace(/[^A-Za-z0-9_.-]/g, '_');
  const stateDir = path.join(scriptDir, 'cost-state');
  fs.mkdirSync(stateDir, { recursive: true });
  const statePath = path.join(stateDir, `statusline-cost-state-${safeSessionId}.json`);
  let previousState = readJsonFile(statePath);
  if (previousState?.session_id !== sessionId) {
    previousState = null;
  }

  const emptyUsage = createUsageSnapshot(null);
  const previousUsage = previousState?.last_cumulative_usage ? createUsageSnapshot(previousState.last_cumulative_usage) : null;
  const refreshUsage = previousUsage ? calculateUsageDelta(currentUsage, previousUsage) : currentUsage;
  let promptUsage;
  let promptStartUsage = null;
  let transcriptOffset = null;

  const eventsPath = getTranscriptEventsPath(transcriptPath);
  if (eventsPath) {
    // A single prompt can trigger many model calls (and statusline refreshes), so prompt
    // boundaries come from user.message events in the transcript, not from usage changes.
    const scan = findNewUserPrompt(eventsPath, getNumber(previousState?.transcript_offset));
    transcriptOffset = scan.offset;

    if (scan.hasNewPrompt) {
      promptStartUsage = previousUsage ?? emptyUsage;
    } else if (previousState?.prompt_start_usage) {
      promptStartUsage = createUsageSnapshot(previousState.prompt_start_usage);
    } else {
      promptStartUsage = previousUsage ?? emptyUsage;
    }

    promptUsage = calculateUsageDelta(currentUsage, promptStartUsage);
  } else if (previousUsage && isSameUsage(currentUsage, previousUsage)) {
    // Without a transcript, fall back to treating each usage change as a prompt.
    promptUsage = previousState.last_prompt_usage;
  } else {
    promptUsage = refreshUsage;
  }

  writeJsonFile(statePath, {
    session_id: sessionId,
    last_cumulative_usage: currentUsage,
    last_prompt_usage: promptUsage,
    prompt_start_usage: promptStartUsage,
    transcript_offset: transcriptOffset,
    updated_at: new Date().toISOString(),
  });

  return { promptUsage, refreshUsage };
}

function formatPricingText(previousCost, sessionCost, todayCost) {
  return `\x1b[36m(Azure) Last prompt: $${previousCost.toFixed(2)} | Session: $${sessionCost.toFixed(2)} | Today: $${todayCost.toFixed(2)}\x1b[0m`;
}

function getDailyCost(additionalCost, shouldIncrement) {
  const dailyDir = path.join(scriptDir, 'daily-cost');
  fs.mkdirSync(dailyDir, { recursive: true });

  const now = new Date();
  const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  const dailyPath = path.join(dailyDir, `${today}.json`);
  let dailyTotal = 0;

  const dailyState = readJsonFile(dailyPath);
  if (dailyState) {
    dailyTotal = getNumber(dailyState.estimated_total_usd);
  }

  if (shouldIncrement) {
    dailyTotal += additionalCost;
    writeJsonFile(dailyPath, {
      date: today,
      estimated_total_usd: dailyTotal,
      updated_at: new Date().toISOString(),
    });
  }

  return dailyTotal;
}

function main() {
  const jsonText = process.env.JSON_INPUT ?? '';
  if (!jsonText.trim()) {
    return;
  }

  const status = JSON.parse(jsonText);

  if ((process.env.COPILOT_PROVIDER_TYPE ?? '').toLowerCase() !== 'azure') {
    return;
  }

  const usage = status.context_window?.current_usage;
  if (!usage) {
    console.log(formatPricingText(0, 0, getDailyCost(0, false)));
    return;
  }

  const pricing = findPricing(status);

  if (!pricing) {
    return;
  }

  const sessionUsage = createUsageSnapshot(usage);
  const usageUpdate = updateSessionUsage(status.session_id, sessionUsage, status.transcript_path);
  const lastPromptCost = usageUpdate.promptUsage ? calculateCost(usageUpdate.promptUsage, pricing) : 0;
  const sessionCost = calculateCost(sessionUsage, pricing);
  const refreshCost = calculateCost(usageUpdate.refreshUsage, pricing);
  const todayCost = getDailyCost(refreshCost, hasUsage(usageUpdate.refreshUsage));
  console.log(formatPricingText(lastPromptCost, sessionCost, todayCost));
}

try {
  main();
} catch {
}
NODE