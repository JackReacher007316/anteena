'use strict';
const assert = require('node:assert/strict');
const { generate } = require('../dashboard/reference_curves.js');

const patch = generate('inset-fed microstrip patch', 2.45);
assert.equal(patch.s11.length, 49);
assert.equal(patch.polar.length, 25);
assert.equal(patch.polar[0].x, 0);
assert.equal(patch.polar.at(-1).x, 360);
assert.equal(patch.s11[24].x, 2.45);
assert.equal(patch.s11[24].y, -19);
assert.equal(patch.modelSpecific, true);
assert.match(patch.disclaimer, /not a CST\/HFSS\/VNA result/i);
assert.ok(patch.polar.every(point => point.y > 0 && point.y <= 1));

const dipole = generate('custom half-wave dipole', 0.915);
assert.equal(dipole.polar.every(point => point.y === 1), true);
assert.equal(dipole.family, 'dipole');

const unknown = generate('my custom antenna type', 5.8);
assert.equal(unknown.modelSpecific, false);
assert.equal(unknown.family, 'user-defined antenna');

assert.throws(() => generate('', 2.4), /antenna type/i);
assert.throws(() => generate('patch', 0), /positive center frequency/i);
console.log('Antenna reference-curve tests passed.');
