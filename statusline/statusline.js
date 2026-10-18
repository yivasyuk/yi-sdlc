const fs = require('fs');
const { execFileSync } = require('child_process');

let input = {};
try {
  input = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {}

const model = input.model?.display_name ?? '?';
const effort = input.effort?.level ?? '';
const pct = Math.max(0, Math.min(100, Math.floor(input.context_window?.used_percentage ?? 0)));
const cost = Number(input.cost?.total_cost_usd ?? 0);
const dir = input.workspace?.current_dir ?? input.cwd ?? process.cwd();

let branch = '';
try {
  branch = execFileSync('git', ['--no-optional-locks', 'branch', '--show-current'], {
    cwd: dir,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
} catch {}

const esc = (code) => `\x1b[${code}m`;
const reset = esc(0);
const COLOR_CONTEXT = '38;5;78';
const COLOR_FIVE_HOUR = '38;5;214';
const COLOR_SEVEN_DAY = '38;5;177';
const COLOR_CACHE = '38;5;110';
const COLOR_DANGER = 31;

// Each bar keeps its own colour; it turns red at 80%+ as a warning.
const makeBar = (value, baseColor) => {
  const filled = Math.floor(value / 10);
  const color = value >= 80 ? COLOR_DANGER : baseColor;
  return `${esc(color)}${'█'.repeat(filled) + '░'.repeat(10 - filled)}${reset} ${value}%`;
};

// Returns a "label bar pct%" segment, or '' when the window is absent.
const limitSegment = (label, window, baseColor) => {
  const raw = window?.used_percentage;
  if (typeof raw !== 'number' || Number.isNaN(raw)) {
    return '';
  }
  const value = Math.max(0, Math.min(100, Math.round(raw)));
  return `${label} ${makeBar(value, baseColor)}`;
};

let out = `${esc(36)}${model}${reset}`;
if (effort) {
  out += ` ${esc(35)}(${effort})${reset}`;
}
out += ` | ${makeBar(pct, COLOR_CONTEXT)}`;
if (branch) {
  out += ` | ${esc(34)}${branch}${reset}`;
}
const fiveHour = limitSegment('5h', input.rate_limits?.five_hour, COLOR_FIVE_HOUR);
if (fiveHour) {
  out += ` | ${fiveHour}`;
}
const sevenDay = limitSegment('7d', input.rate_limits?.seven_day, COLOR_SEVEN_DAY);
if (sevenDay) {
  out += ` | ${sevenDay}`;
}
const hitRatio = input.prompt_cache?.hit_ratio;
if (typeof hitRatio === 'number' && !Number.isNaN(hitRatio)) {
  const cachePct = Math.max(0, Math.min(100, Math.round(hitRatio * 100)));
  out += ` | ${esc(COLOR_CACHE)}cache ${cachePct}%${reset}`;
}
out += ` | ${esc(33)}$${cost.toFixed(2)}${reset}`;

process.stdout.write(out);
