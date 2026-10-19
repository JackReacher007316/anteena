"""
data_loader.py
ML Antenna Framework — Dataset Loader
Loads and generates sample antenna datasets (real or synthetic)
"""

import numpy as np
import pandas as pd
from pathlib import Path
from typing import Tuple, Dict, Optional
import warnings
warnings.filterwarnings('ignore')


# ─────────────────────────────────────────────────────────
# 1. Real Data Loader (from CST exports)
# ─────────────────────────────────────────────────────────

class AntennaDataLoader:
    """
    Loads antenna simulation data from CSV files (exported from CST).
    Supports: Patch, MIMO, UWB, 5G/mmWave, Fractal
    """

    ANTENNA_CONFIGS = {
        'patch': {
            'features': ['Length_mm', 'Width_mm', 'Height_mm', 'Permittivity'],
            'targets':  ['S11_dB', 'Gain_dBi', 'Bandwidth_GHz', 'Resonant_Freq_GHz'],
            'freq_range': (1, 6),
        },
        'mimo': {
            'features': ['Spacing_lambda', 'Length_mm'],
            'targets':  ['S11_dB', 'S21_dB', 'Isolation_dB', 'ECC', 'TARC_dB'],
            'freq_range': (2, 8),
        },
        'uwb': {
            'features': ['SlotWidth_mm', 'SlotLength_mm', 'GndCutout_mm', 'FeedGap_mm'],
            'targets':  ['S11min_dB', 'Bandwidth_GHz', 'GroupDelay_ns', 'FidelityFactor'],
            'freq_range': (3.1, 10.6),
        },
        '5g': {
            'features': ['ElementSpacing_mm', 'PatchLength_mm', 'PatchWidth_mm', 'ArrayRows', 'ArrayCols'],
            'targets':  ['S11_dB', 'Gain_dBi', 'Beamwidth_deg', 'SLL_dB'],
            'freq_range': (24, 40),
        },
        'fractal': {
            'features': ['IterationLevel', 'ScaleFactor', 'BaseLength_mm', 'SubstrateH_mm'],
            'targets':  ['S11_dB', 'Gain_dBi', 'Bandwidth_GHz'],
            'freq_range': (1, 12),
        },
        'horn': {
            'features': ['A_flare_mm', 'B_flare_mm', 'L_horn_mm'],
            'targets':  ['S11_dB', 'Gain_dBi', 'Beamwidth_E_deg', 'Beamwidth_H_deg'],
            'freq_range': (8, 12.5),
        },
        'helical': {
            'features': ['Diameter_mm', 'Spacing_mm', 'Num_Turns'],
            'targets':  ['S11_dB', 'Gain_dBi', 'Axial_Ratio_dB', 'HPBW_deg'],
            'freq_range': (1.8, 3.0),
        },
        'dipole': {
            'features': ['Length_mm', 'Wire_Radius_mm', 'Feed_Gap_mm'],
            'targets':  ['S11_dB', 'Gain_dBi', 'Bandwidth_GHz'],
            'freq_range': (1.5, 3.5),
        },
        'yagi': {
            'features': ['Num_Directors', 'Director_Spacing_mm', 'Reflector_Length_mm'],
            'targets':  ['S11_dB', 'Gain_dBi', 'Front_to_Back_dB', 'Beamwidth_deg'],
            'freq_range': (2.0, 2.8),
        },
        'dra': {
            'features': ['Radius_mm', 'Height_mm', 'Permittivity', 'Slot_Length_mm'],
            'targets':  ['S11_dB', 'Gain_dBi', 'Bandwidth_pct', 'Efficiency_pct'],
            'freq_range': (4.5, 7.0),
        },
        'bowtie': {
            'features': ['Arm_Length_mm', 'Flare_Width_mm', 'Feed_Gap_mm', 'Permittivity'],
            'targets':  ['S11_min_dB', 'Bandwidth_GHz', 'Peak_Gain_dBi'],
            'freq_range': (1.5, 5.0),
        },
    }

    def __init__(self, antenna_type: str, data_dir: str = '../data/raw/'):
        self.antenna_type = antenna_type.lower()
        self.data_dir = Path(data_dir)
        if self.antenna_type not in self.ANTENNA_CONFIGS:
            raise ValueError(f"Unknown antenna type: {antenna_type}. "
                             f"Choose from: {list(self.ANTENNA_CONFIGS.keys())}")
        self.config = self.ANTENNA_CONFIGS[self.antenna_type]

    def load(self, filename: Optional[str] = None) -> pd.DataFrame:
        """Load from CSV file or generate synthetic data if not found."""
        if filename:
            filepath = self.data_dir / filename
        else:
            filepath = self.data_dir / f'{self.antenna_type}_sweep_results.csv'

        if filepath.exists():
            print(f"[DataLoader] Loading: {filepath}")
            df = pd.read_csv(filepath)
            print(f"[DataLoader] Loaded {len(df)} samples")
            return df
        
        # Check samples directory
        sample_path = Path(__file__).parent.parent / 'data' / 'samples' / f'{self.antenna_type}_sample_data.csv'
        if sample_path.exists():
            print(f"[DataLoader] Loading sample dataset: {sample_path}")
            df = pd.read_csv(sample_path)
            if len(df) >= 5:
                return df

        print(f"[DataLoader] Generating synthetic dataset for {self.antenna_type}...")
        return self.generate_synthetic_dataset(n_samples=1000)

    def generate_synthetic_dataset(self, n_samples: int = 1000) -> pd.DataFrame:
        """
        Generate physically-motivated synthetic antenna dataset.
        Based on simplified analytical antenna models.
        """
        np.random.seed(42)
        
        if self.antenna_type == 'patch':
            return self._gen_patch(n_samples)
        elif self.antenna_type == 'mimo':
            return self._gen_mimo(n_samples)
        elif self.antenna_type == 'uwb':
            return self._gen_uwb(n_samples)
        elif self.antenna_type == '5g':
            return self._gen_5g(n_samples)
        elif self.antenna_type == 'fractal':
            return self._gen_fractal(n_samples)

    def _gen_patch(self, n: int) -> pd.DataFrame:
        """Patch antenna — Hammerstein model approximation"""
        L  = np.random.uniform(10, 40, n)   # mm
        W  = np.random.uniform(10, 40, n)   # mm
        h  = np.random.uniform(0.5, 3.0, n) # mm
        er = np.random.choice([2.2, 3.5, 4.4, 6.15, 9.8], n)

        # Resonant frequency (simplified Hammerstein formula)
        c = 3e8  # speed of light
        er_eff = (er + 1)/2 + (er - 1)/2 * (1 + 12*h/W)**(-0.5)
        L_eff  = L + 0.824*h * ((er_eff + 0.3)*(W/h + 0.264)) / \
                              ((er_eff - 0.258)*(W/h + 0.8))
        fr = c / (2 * L_eff * 1e-3 * np.sqrt(er_eff)) / 1e9  # GHz

        # S11 (minimum), gain, bandwidth — physics-inspired + noise
        S11  = -10 - 5*np.log(er) + np.random.normal(0, 1.5, n)
        S11  = np.clip(S11, -35, -5)
        Gain = 5 + 0.05*W - 0.1*h + np.random.normal(0, 0.5, n)
        BW   = 0.02 * fr * (h/er) + np.random.normal(0, 0.05, n)
        BW   = np.abs(BW)

        return pd.DataFrame({
            'Length_mm': L, 'Width_mm': W, 'Height_mm': h,
            'Permittivity': er,
            'S11_dB': S11, 'Gain_dBi': Gain,
            'Bandwidth_GHz': BW, 'Resonant_Freq_GHz': fr
        })

    def _gen_mimo(self, n: int) -> pd.DataFrame:
        spacing = np.random.uniform(0.05, 0.5, n)
        length  = np.random.uniform(15, 35, n)

        S11  = -15 + 5*np.exp(-spacing*3) + np.random.normal(0, 1.0, n)
        S21  = -5 - 15*spacing + np.random.normal(0, 1.5, n)
        iso  = np.abs(S21)
        ECC  = np.exp(-3*spacing) * np.random.uniform(0.1, 0.9, n)
        ECC  = np.clip(ECC, 0, 1)
        TARC = (S11 + S21 - 3) / 2 + np.random.normal(0, 0.5, n)

        return pd.DataFrame({
            'Spacing_lambda': spacing, 'Length_mm': length,
            'S11_dB': S11, 'S21_dB': S21, 'Isolation_dB': iso,
            'ECC': ECC, 'TARC_dB': TARC
        })

    def _gen_uwb(self, n: int) -> pd.DataFrame:
        sw = np.random.uniform(8, 20, n)
        sl = np.random.uniform(8, 20, n)
        gc = np.random.uniform(2, 10, n)
        fg = np.random.uniform(0.5, 2.0, n)

        S11min = -20 - 0.3*sw + 0.2*gc + np.random.normal(0, 1.5, n)
        BW     = 5 + 0.1*sw + 0.2*sl - 0.5*fg + np.random.normal(0, 0.3, n)
        GD     = 1.5 - 0.05*gc + np.random.normal(0, 0.2, n)
        FF     = 0.9 - 0.01*(fg - 1)**2 + np.random.normal(0, 0.02, n)

        return pd.DataFrame({
            'SlotWidth_mm': sw, 'SlotLength_mm': sl,
            'GndCutout_mm': gc, 'FeedGap_mm': fg,
            'S11min_dB': np.clip(S11min, -40, -10),
            'Bandwidth_GHz': np.clip(BW, 3, 10),
            'GroupDelay_ns': np.abs(GD),
            'FidelityFactor': np.clip(FF, 0.7, 1.0)
        })

    def _gen_5g(self, n: int) -> pd.DataFrame:
        es  = np.random.uniform(0.4, 1.5, n)  # element spacing (lambda)
        pl  = np.random.uniform(2, 6, n)      # patch length mm
        pw  = np.random.uniform(2, 6, n)      # patch width mm
        ar  = np.random.randint(1, 5, n)      # array rows
        ac  = np.random.randint(1, 5, n)      # array cols

        S11  = -20 + 3*(es-0.5)**2 + np.random.normal(0, 1, n)
        Gain = 8 + 3*np.log2(ar*ac) + np.random.normal(0, 0.5, n)
        BW_d = 40 - 5*(es-0.5)**2 + np.random.normal(0, 3, n)
        SLL  = -13 - 2*np.log(ar*ac) + np.random.normal(0, 1, n)

        return pd.DataFrame({
            'ElementSpacing_mm': es, 'PatchLength_mm': pl,
            'PatchWidth_mm': pw, 'ArrayRows': ar, 'ArrayCols': ac,
            'S11_dB': np.clip(S11, -35, -5), 'Gain_dBi': Gain,
            'Beamwidth_deg': np.clip(BW_d, 5, 60), 'SLL_dB': SLL
        })

    def _gen_fractal(self, n: int) -> pd.DataFrame:
        it = np.random.randint(1, 5, n)
        sf = np.random.uniform(0.3, 0.7, n)
        bl = np.random.uniform(20, 60, n)
        sh = np.random.uniform(0.5, 3.0, n)

        S11  = -15 - 2*it + np.random.normal(0, 1.5, n)
        Gain = 3 + 0.5*it + np.random.normal(0, 0.5, n)
        BW   = 1 + 0.5*it + np.random.normal(0, 0.2, n)

        return pd.DataFrame({
            'IterationLevel': it, 'ScaleFactor': sf,
            'BaseLength_mm': bl, 'SubstrateH_mm': sh,
            'S11_dB': np.clip(S11, -35, -5),
            'Gain_dBi': Gain,
            'Bandwidth_GHz': np.clip(BW, 0.1, 8)
        })


# ─────────────────────────────────────────────────────────
# 2. Quick-access utility
# ─────────────────────────────────────────────────────────

def load_antenna_data(antenna_type: str, target: str = 'S11_dB',
                      n_samples: int = 1000) -> Dict:
    """
    Convenience function: returns dict with X_train, X_test, y_train, y_test.
    """
    from feature_engineering import AntennaFeatureEngineer

    loader = AntennaDataLoader(antenna_type)
    df = loader.generate_synthetic_dataset(n_samples)

    feature_cols = loader.config['features']
    X = df[feature_cols].values
    y = df[target].values

    engineer = AntennaFeatureEngineer(antenna_type)
    X_train, X_test, y_train, y_test, scaler = engineer.fit_transform(X, y)

    return {
        'X_train': X_train, 'X_test': X_test,
        'y_train': y_train, 'y_test': y_test,
        'scaler': scaler,
        'feature_names': feature_cols,
        'target_name': target,
        'antenna_type': antenna_type,
        'raw_df': df,
    }


if __name__ == '__main__':
    print("=== Antenna Data Loader Test ===")
    for ant_type in ['patch', 'mimo', 'uwb', '5g', 'fractal']:
        loader = AntennaDataLoader(ant_type)
        df = loader.generate_synthetic_dataset(500)
        print(f"  {ant_type:10s}: {df.shape[0]} samples, {df.shape[1]} columns")
        print(f"    Features: {loader.config['features']}")
        print(f"    Targets : {loader.config['targets']}")
        print()
