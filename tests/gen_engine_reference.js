#!/usr/bin/env node
/**
 * gen_engine_reference.js
 *
 * Evaluates the dashboard's JavaScript EM engines (dashboard/app.js ->
 * ANTENNA_CONFIGS[*].simulate and generateS11Curve) and stores reference
 * outputs in tests/fixtures/engine_reference.json.
 *
 * matlab/test_antenna_model.m uses this file to prove that MATLAB's
 * independent re-implementation (antenna_model.m / antenna_s11_curve.m)
 * reproduces the dashboard exactly. Re-run after changing any formula:
 *
 *     node tests/gen_engine_reference.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const src = fs.readFileSync(path.join(ROOT, 'dashboard', 'app.js'), 'utf8');

function slice(startMarker, endMarker) {
  const a = src.indexOf(startMarker);
  const b = src.indexOf(endMarker, a);
  if (a < 0 || b < 0) throw new Error(`markers not found: ${startMarker} / ${endMarker}`);
  return src.slice(a, b);
}

// Pull the engine table and the S11 curve generator out of the browser code.
const configsSrc = slice('const ANTENNA_CONFIGS', '// 2. REAL ML MODEL ACCURACY SCORES');
const curveSrc = slice('function generateS11Curve', 'function drawChart');
const ANTENNA_CONFIGS = new Function(`${configsSrc}; return ANTENNA_CONFIGS;`)();
const generateS11Curve = new Function(`${curveSrc}; return generateS11Curve;`)();

// Deterministic PRNG (mulberry32) so the fixture is reproducible.
function mulberry32(seed) {
  return function rand() {
    seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = mulberry32(20261019);

function snap(p, v) {
  const n = Math.round((v - p.min) / p.step);
  return Math.min(p.max, Math.max(p.min, +(p.min + n * p.step).toFixed(6)));
}

function numericOnly(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v === 'number' && Number.isFinite(v)) out[k] = v;
  }
  return out;
}

// S11 traces are stored for a representative subset (fractal = multi-band case).
const CURVE_ANTENNAS = ['patch', 'fractal', 'uwb', '5g', 'dipole', 'whip'];

const antennas = [];
for (const [key, cfg] of Object.entries(ANTENNA_CONFIGS)) {
  const defaults = Object.fromEntries(cfg.params.map(p => [p.id, p.default]));
  const inputs = [
    defaults,
    Object.fromEntries(cfg.params.map(p => [p.id, p.min])),
    Object.fromEntries(cfg.params.map(p => [p.id, p.max])),
  ];
  for (let i = 0; i < 4; i++) {          // slider positions (snapped to step)
    inputs.push(Object.fromEntries(cfg.params.map(p => [p.id, snap(p, p.min + rand() * (p.max - p.min))])));
  }
  for (let i = 0; i < 2; i++) {          // arbitrary values inside the range
    inputs.push(Object.fromEntries(cfg.params.map(p => [p.id, p.min + rand() * (p.max - p.min)])));
  }

  const cases = inputs.map(params => ({ params, outputs: numericOnly(cfg.simulate(params)) }));

  const entry = {
    key,
    name: cfg.fullName,
    freq_range: cfg.freqRange,
    params: cfg.params.map(p => ({ id: p.id, label: p.label, min: p.min, max: p.max, step: p.step, default: p.default })),
    cases,
  };
  if (CURVE_ANTENNAS.includes(key)) {
    // Noise-free S11 trace (noise = 0, offset = 0) on the dashboard's 200-point
    // grid: f = linspace(freq_range(1), freq_range(2), 200).
    const params = inputs[3];
    entry.curve = { params, s11: generateS11Curve(cfg, params, 0, 0).vals };
  }
  antennas.push(entry);
}

const fixture = {
  generated_by: 'tests/gen_engine_reference.js',
  source: 'dashboard/app.js (ANTENNA_CONFIGS.*.simulate, generateS11Curve)',
  antenna_count: antennas.length,
  antennas,
};

const outFile = path.join(ROOT, 'tests', 'fixtures', 'engine_reference.json');
fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(fixture));
const nCases = antennas.reduce((n, a) => n + a.cases.length, 0);
console.log(`wrote ${path.relative(ROOT, outFile)}: ${antennas.length} antennas, ${nCases} cases`);
