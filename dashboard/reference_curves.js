/*
 * Illustrative antenna reference curves for geometry/photo uploads.
 * These are deterministic templates, NOT CST/HFSS simulations or measurements.
 * They must always be displayed with the estimated-data disclaimer.
 */
(function (root) {
  'use strict';

  const FAMILY_PROFILES = [
    { name: 'phased array', tokens: ['phased array', 'phased-array', 'array'], bandwidth: 0.08, pattern: 'directive', hpbw: 35 },
    { name: 'parabolic reflector', tokens: ['parabolic', 'dish'], bandwidth: 0.12, pattern: 'directive', hpbw: 30 },
    { name: 'horn', tokens: ['horn'], bandwidth: 0.18, pattern: 'directive', hpbw: 50 },
    { name: 'yagi / log-periodic', tokens: ['yagi', 'log-periodic', 'log periodic', 'lpda'], bandwidth: 0.16, pattern: 'directive', hpbw: 60 },
    { name: 'helix', tokens: ['helical', 'helix'], bandwidth: 0.22, pattern: 'directive', hpbw: 65 },
    { name: 'vivaldi / tapered slot', tokens: ['vivaldi', 'tapered slot'], bandwidth: 0.45, pattern: 'directive', hpbw: 60 },
    { name: 'bowtie', tokens: ['bowtie', 'bow tie'], bandwidth: 0.40, pattern: 'bidirectional', hpbw: 90 },
    { name: 'slot', tokens: ['slot'], bandwidth: 0.12, pattern: 'bidirectional', hpbw: 90 },
    { name: 'discone', tokens: ['discone'], bandwidth: 0.45, pattern: 'omnidirectional', hpbw: 360 },
    { name: 'monopole / whip', tokens: ['monopole', 'whip', 'pifa'], bandwidth: 0.20, pattern: 'omnidirectional', hpbw: 360 },
    { name: 'dipole', tokens: ['dipole'], bandwidth: 0.12, pattern: 'omnidirectional', hpbw: 360 },
    { name: 'patch / DRA', tokens: ['patch', 'dra', 'dielectric resonator'], bandwidth: 0.06, pattern: 'directive', hpbw: 85 },
    { name: 'fractal', tokens: ['fractal'], bandwidth: 0.12, pattern: 'directive', hpbw: 85 },
    { name: 'spiral', tokens: ['spiral'], bandwidth: 0.50, pattern: 'bidirectional', hpbw: 90 },
    { name: 'MIMO', tokens: ['mimo'], bandwidth: 0.10, pattern: 'directive', hpbw: 85 }
  ];

  function selectProfile(antennaType) {
    const normalized = String(antennaType || '').toLowerCase();
    return FAMILY_PROFILES.find(profile => profile.tokens.some(token => normalized.includes(token))) || {
      name: 'user-defined antenna', bandwidth: 0.10, pattern: 'directive', hpbw: 90
    };
  }

  function generate(antennaType, centerFrequencyGHz) {
    const type = String(antennaType || '').trim();
    const f0 = Number(centerFrequencyGHz);
    if (!type) throw new TypeError('Enter an antenna type to create reference curves.');
    if (!Number.isFinite(f0) || f0 <= 0 || f0 > 1000) {
      throw new RangeError('Enter a positive center frequency in GHz (maximum 1000 GHz).');
    }

    const profile = selectProfile(type);
    const bandwidthGHz = f0 * profile.bandwidth;
    const spanGHz = Math.max(bandwidthGHz * 1.6, f0 * 0.02);
    const startGHz = Math.max(f0 - spanGHz, f0 * 0.01);
    const stopGHz = f0 + spanGHz;
    const s11 = [];
    const pointCount = 49;
    for (let i = 0; i < pointCount; i += 1) {
      const frequency = startGHz + (stopGHz - startGHz) * i / (pointCount - 1);
      const normalizedOffset = 2 * (frequency - f0) / bandwidthGHz;
      const db = -1 - 18 / (1 + normalizedOffset * normalizedOffset);
      s11.push({ x: Number(frequency.toFixed(6)), y: Number(db.toFixed(3)) });
    }

    const polar = [];
    for (let angle = 0; angle <= 360; angle += 15) {
      let level;
      if (profile.pattern === 'omnidirectional') {
        // Idealized horizontal-plane reference cut.
        level = 1;
      } else if (profile.pattern === 'bidirectional') {
        level = Math.max(0.025, Math.abs(Math.sin(angle * Math.PI / 180)));
      } else {
        const distance = Math.min(angle, 360 - angle);
        const mainLobe = Math.exp(-4 * Math.LN2 * (distance / profile.hpbw) ** 2);
        const backLobe = 0.04 * Math.exp(-4 * Math.LN2 * ((180 - distance) / 32) ** 2);
        level = Math.max(0.025, mainLobe, backLobe);
      }
      polar.push({ x: angle, y: Number(level.toFixed(4)) });
    }

    return {
      antennaType: type,
      family: profile.name,
      centerFrequencyGHz: f0,
      estimatedBandwidth10dBGHz: bandwidthGHz,
      estimatedMinimumS11dB: -19,
      patternPlane: profile.pattern === 'omnidirectional' ? 'idealized azimuth / H-plane' : 'generic principal-plane reference cut',
      modelSpecific: profile.name !== 'user-defined antenna',
      s11,
      polar,
      disclaimer: 'Illustrative reference template only. Not digitized from the image, not predicted from dimensions, and not a CST/HFSS/VNA result. Run a full-wave solver or upload exported sweep data for engineering values.'
    };
  }

  const api = { generate, selectProfile };
  root.AntennaReferenceCurves = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
