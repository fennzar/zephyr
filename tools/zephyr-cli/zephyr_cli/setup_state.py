"""Devnet state setup — dynamic minting sequences for bootstrapping network state."""

import time

import requests

from .formatting import COIN

EXPLORER_API = 'https://explorer.zephyrprotocol.com/api'

# Hardcoded fallback supply targets for mirror mode (whole units)
MIRROR_DEFAULTS = {
    'djed': 3_500_000,
    'total_zsd': 600_000,
    'yield': 200_000,
}


def _log(msg):
    print(msg, flush=True)


class SetupState:
    """Run the devnet minting sequence.

    Two modes:
    - custom: RR-targeted minting (ZRS, ZSD with predictive stopping, ZYS, fund, ring)
    - mirror: Mint to match mainnet supply targets from explorer API
    """

    def __init__(self, client, mode='custom', target_rr=7.0,
                 zsd_mint_limit=450000, oracle_price=None):
        self.client = client
        self.mode = mode
        self.target_rr = target_rr
        self.zsd_mint_limit = zsd_mint_limit
        self.oracle_price = oracle_price

    def run(self):
        if self.oracle_price is not None:
            self.client.set_price(self.oracle_price)
            _log(f'Oracle price set to ${self.oracle_price:.2f}')

        # Refresh gov wallet before starting
        self.client.refresh('gov')

        if self.mode == 'mirror':
            self._run_mirror()
        else:
            self._run_custom()

    # ── Custom mode ──────────────────────────────────────────────────

    def _run_custom(self):
        _log(f'Custom mode: target RR={self.target_rr} ({self.target_rr * 100:.0f}%), '
             f'ZSD limit={self.zsd_mint_limit:,}')
        _log('')

        self._phase_zrs()
        self._phase_zsd()
        self._phase_zys()
        self._phase_fund()
        self._phase_ring()

        # Final summary
        _log('')
        _log('--- Custom mode supply summary ---')
        rr = self._get_reserve_ratio()
        _log(f'  Reserve ratio: {rr:.2f} ({rr * 100:.0f}%)')
        self._print_supply_summary()

    def _phase_zrs(self):
        """Phase 1: Mint ZRS (3 x 500K ZPH -> ZRS).

        More ZRS raises the reserve ratio, giving Phase 2 room to mint
        enough ZSD for seeding (~155K) + ZYS (~94K) + test (5K).
        """
        ZRS_ROUNDS = 3
        ZRS_CHUNK = 500_000
        _log(f'--- Phase 1: Mint ZRS ({ZRS_ROUNDS} x {ZRS_CHUNK:,} ZPH -> ZRS) ---')
        for i in range(1, ZRS_ROUNDS + 1):
            _log(f'  ZRS mint {i}/{ZRS_ROUNDS}:')
            self.client.convert('gov', ZRS_CHUNK, 'ZPH', 'ZRS')
            self._wait_blocks(12)
        _log('Phase 1 complete (ZRS minted)')
        _log('')
        _log('--- Waiting for ZPH outputs to unlock ---')
        self._wait_blocks(12)

    def _phase_zsd(self):
        """Phase 2: Mint ZSD until supply cap OR RR floor is reached.

        Uses 100K ZPH per round, then an adaptive final round to land
        close to the target RR (max 3 rounds total).
        """
        ZSD_ROUNDS_MAX = 3
        ZSD_CHUNK = 100_000

        _log('')
        _log(f'--- Phase 2: Mint ZSD (up to {ZSD_ROUNDS_MAX} rounds, '
             f'cap {self.zsd_mint_limit:,}, RR target {self.target_rr}) ---')

        zsd_before = self._get_supply_field('num_stables')
        zsd_limit_atomic = int(self.zsd_mint_limit * COIN)
        prev_rr = None
        rounds = 0

        for i in range(1, ZSD_ROUNDS_MAX + 1):
            zsd_now = self._get_supply_field('num_stables')
            zsd_minted = zsd_now - zsd_before
            rr = self._get_reserve_ratio()

            if i > 1:
                _log(f'    RR: {rr:.4f}, ZSD minted: {zsd_minted / COIN:,.0f}')

            # Stop if cap reached
            if zsd_minted >= zsd_limit_atomic:
                _log(f'  ZSD cap reached ({zsd_minted / COIN:,.0f} >= {self.zsd_mint_limit:,}), stopping')
                break

            # Stop if RR at/below target
            if i > 1 and rr > 0:
                if rr <= self.target_rr:
                    _log(f'  RR reached {rr:.4f} <= target {self.target_rr}, stopping')
                    break
                # Predictive stop: if a full chunk would overshoot, use adaptive amount
                if prev_rr is not None:
                    drop = prev_rr - rr
                    predicted = rr - drop
                    if predicted <= self.target_rr:
                        # Calculate exact ZPH to land at target RR
                        adaptive = self._calc_adaptive_zsd_amount(rr)
                        if adaptive and adaptive >= 5_000:
                            _log(f'  Adaptive final round: {adaptive:,} ZPH (target RR {self.target_rr})')
                            self.client.convert('gov', adaptive, 'ZPH', 'ZSD')
                            rounds = i
                            self._wait_blocks(12)
                        else:
                            _log(f'  Full chunk would overshoot, adaptive too small, stopping')
                        break

            prev_rr = rr
            _log(f'  ZSD mint {i}/{ZSD_ROUNDS_MAX}:')
            self.client.convert('gov', ZSD_CHUNK, 'ZPH', 'ZSD')
            rounds = i
            self._wait_blocks(12)

        rr_after = self._get_reserve_ratio()
        zsd_final = self._get_supply_field('num_stables')
        zsd_total = (zsd_final - zsd_before) / COIN
        _log(f'Phase 2 complete ({rounds} rounds, {zsd_total:,.0f} ZSD minted, RR={rr_after:.4f})')
        _log('')
        _log('--- Waiting for ZSD outputs to unlock ---')
        self._wait_blocks(12)

    def _phase_zys(self):
        """Phase 3: Mint ZYS from ZSD (up to 4 rounds of 25K each).

        Checks available ZSD balance before each round and caps the amount.
        Reserves 6K ZSD for later phases (5K fund test + 1K ring diversity).
        """
        ZYS_CHUNK = 25_000
        ZYS_ROUNDS = 4
        ZSD_RESERVE = 6_000  # phases 4+5 need ZSD

        _log('')
        _log(f'--- Phase 3: Mint ZYS (up to {ZYS_ROUNDS} x {ZYS_CHUNK:,} ZSD -> ZYS) ---')

        minted = 0
        for i in range(1, ZYS_ROUNDS + 1):
            bals = self.client.balances('gov')
            zsd_unlocked = bals.get('gov', {}).get('ZSD', 0) / COIN
            available = zsd_unlocked - ZSD_RESERVE

            if available < 1_000:
                _log(f'  Insufficient ZSD (unlocked {zsd_unlocked:,.0f}, reserve {ZSD_RESERVE:,}), '
                     f'stopping after {i - 1} rounds')
                break

            amount = min(ZYS_CHUNK, int(available))
            _log(f'  ZYS mint {i}/{ZYS_ROUNDS}: {amount:,} ZSD -> ZYS')
            self.client.convert('gov', amount, 'ZSD', 'ZYS')
            minted += amount
            self._wait_blocks(12)

        _log(f'Phase 3 complete ({minted:,} ZSD converted to ZYS)')
        _log('')
        _log('--- Waiting for outputs to unlock ---')
        self._wait_blocks(12)

    def _phase_fund(self):
        """Phase 4: Fund test and miner wallets."""
        _log('')
        _log('--- Phase 4: Fund test and miner wallets ---')
        for i in range(1, 4):
            _log(f'  ZPH send {i}/3: 10,000 -> test')
            self.client.send('gov', 'test', 10_000, 'ZPH')
            self._wait_blocks(12)
        _log('  ZSD send: 5,000 -> test')
        self.client.send('gov', 'test', 5_000, 'ZSD')
        self._wait_blocks(12)
        _log('  ZPH send: 5,000 -> miner')
        self.client.send('gov', 'miner', 5_000, 'ZPH')
        self._wait_blocks(12)
        _log('Phase 4 complete (wallets funded)')

    def _phase_ring(self):
        """Phase 5: Ring diversity (self-sends for ring signature decoys).

        Refreshes wallet before each send so the wallet sees newly unlocked
        change outputs from prior transactions.
        """
        _log('')
        _log('--- Phase 5: Ring diversity (self-sends) ---')
        for i in range(1, 5):
            self.client.refresh('gov')
            _log(f'  ZPH self-send {i}/4: 1,000')
            self.client.send('gov', 'gov', 1_000, 'ZPH')
            self._wait_blocks(12)
        for i in range(1, 3):
            self.client.refresh('gov')
            _log(f'  ZSD self-send {i}/2: 500')
            self.client.send('gov', 'gov', 500, 'ZSD')
            self._wait_blocks(12)
        _log('Phase 5 complete (ring diversity)')
        _log('')
        _log('--- Final wait for all outputs to unlock ---')
        self._wait_blocks(12)

    # ── Mirror mode ──────────────────────────────────────────────────

    def _run_mirror(self):
        _log('--- Mirror Mode: Fetching mainnet supply targets ---')
        targets = self._fetch_mainnet_supply()

        total_zsd_needed = targets['total_zsd'] + targets['yield'] + 50_000
        _log(f'  Supply targets:')
        _log(f'    DJED:  {targets["djed"]:,}')
        _log(f'    ZSD:   {targets["total_zsd"]:,}')
        _log(f'    YIELD: {targets["yield"]:,}')
        _log(f'    Total ZSD to mint: {total_zsd_needed:,}')
        _log('')

        # M1: Set price high for ZRS minting
        _log('--- Phase M1: Mint ZRS (target DJED) ---')
        self.client.set_price(15.00)
        self._wait_blocks(5)
        self._mint_until_target('ZPH', 'ZRS', 'num_reserves', targets['djed'], 300_000, 'DJED')
        _log('Phase M1 complete (ZRS/DJED minted)')
        _log('')
        self._wait_blocks(12)

        # M2: Mint ZSD
        _log('--- Phase M2: Mint ZSD ---')
        self._mint_until_target('ZPH', 'ZSD', 'num_stables', total_zsd_needed, 50_000, 'ZSD (total)')
        _log('Phase M2 complete (ZSD minted)')
        _log('')
        self._wait_blocks(12)

        # M3: Mint ZYS
        _log('--- Phase M3: Mint ZYS ---')
        self._mint_until_target('ZSD', 'ZYS', 'num_zyield', targets['yield'], 25_000, 'YIELD')
        _log('Phase M3 complete (ZYS/YIELD minted)')
        _log('')
        self._wait_blocks(12)

        # M4-M5: Fund wallets + ring diversity (shared with custom mode)
        self._phase_fund()
        self._phase_ring()

        # M6: Set mainnet price
        _log('--- Phase M6: Set oracle to actual mainnet price ---')
        mainnet_spot = self._fetch_mainnet_spot_price()
        if mainnet_spot:
            usd = mainnet_spot / COIN
            self.client.set_price(usd)
            _log(f'  Oracle set to mainnet price: ${usd:.2f}')
        else:
            _log('  Could not fetch mainnet price, keeping current price')

        _log('')
        self._print_supply_summary()

    def _mint_until_target(self, from_asset, to_asset, target_field, target_value,
                           chunk_size, label):
        """Mint in rounds until target supply field is approximately reached (5% tolerance)."""
        target_atomic = int(target_value * COIN)
        chunk_atomic = int(chunk_size * COIN)
        tolerance = int(target_atomic * 0.05)

        _log(f'  Target: {label} = {target_value:,} (tolerance: {tolerance / COIN:,.0f})')

        for round_num in range(1, 51):
            self.client.refresh('gov')
            current_atomic = self._get_supply_field(target_field)
            delta = target_atomic - current_atomic

            _log(f'    Round {round_num}: current={current_atomic / COIN:,.0f}, '
                 f'target={target_value:,}, delta={delta / COIN:,.0f}')

            if delta <= tolerance:
                _log(f'  {label} reached target ({current_atomic / COIN:,.0f})')
                return

            if delta < 0:
                _log(f'  {label} overshot ({current_atomic / COIN:,.0f} > {target_value:,}), continuing')
                return

            mint_amount = min(chunk_atomic, delta)
            self.client.convert('gov', int(mint_amount) // COIN, from_asset, to_asset)
            self._wait_blocks(12)

        _log(f'  WARNING: {label} did not reach target after 50 rounds')

    def _fetch_mainnet_supply(self):
        """Fetch mainnet supply targets from explorer API."""
        _log('  Fetching mainnet supply from explorer...')
        try:
            resp = requests.get(f'{EXPLORER_API}/supply', timeout=10)
            data = resp.json().get('data', {})
            djed = int(float(data.get('djed', 0)))
            if djed > 0:
                targets = {
                    'djed': djed,
                    'total_zsd': int(float(data.get('zsd', 0))),
                    'yield': int(float(data.get('yield', 0))),
                }
                _log(f'  Mainnet supply fetched: {targets}')
                return targets
        except Exception:
            pass
        _log(f'  Explorer API unavailable, using hardcoded defaults: {MIRROR_DEFAULTS}')
        return MIRROR_DEFAULTS.copy()

    def _fetch_mainnet_spot_price(self):
        """Fetch mainnet oracle spot price (returns atomic or None)."""
        try:
            ts = int(time.time())
            resp = requests.get(
                f'https://oracle.zephyrprotocol.com/price/?timestamp={ts}&version=11',
                timeout=10)
            return int(resp.json()['pr']['spot'])
        except Exception:
            return None

    # ── Helpers ───────────────────────────────────────────────────────

    def _calc_adaptive_zsd_amount(self, current_rr):
        """Calculate ZPH needed to reach target RR from current state.

        Uses: target_rr = (R + Δ) / (L + Δ), solved for Δ in ZSD terms,
        then converted to ZPH via stable rate. Returns whole ZPH or None.
        """
        try:
            info = self.client.reserve_info()
            zsd_supply = int(info.get('num_stables', 0)) / COIN
            stable_rate = float(info.get('pr', {}).get('stable', 0)) / COIN
            if zsd_supply <= 0 or stable_rate <= 0 or self.target_rr <= 1:
                return None
            reserves = current_rr * zsd_supply  # R in ZSD terms
            # Δ = (R - target * L) / (target - 1)
            delta_zsd = (reserves - self.target_rr * zsd_supply) / (self.target_rr - 1)
            if delta_zsd <= 0:
                return None
            # stable_rate = ZPH per ZSD, so ZPH = delta_zsd * stable_rate
            zph_needed = int(delta_zsd * stable_rate)
            return zph_needed if zph_needed > 0 else None
        except Exception:
            return None

    def _get_reserve_ratio(self):
        """Get current reserve ratio as float."""
        try:
            info = self.client.reserve_info()
            return float(info.get('reserve_ratio', 0))
        except Exception:
            return 0.0

    def _get_supply_field(self, field):
        """Get a supply field value in atomic units."""
        try:
            info = self.client.reserve_info()
            return int(info.get(field, 0))
        except Exception:
            return 0

    def _wait_blocks(self, n):
        """Wait for n blocks to be mined from the current height."""
        current = self.client.height()
        self.client.wait_for_height(current + n)

    def _print_supply_summary(self):
        """Print current supply state."""
        _log('--- Supply summary ---')
        try:
            info = self.client.reserve_info()
            for field in ['num_reserves', 'num_stables', 'num_zyield']:
                _log(f'  {field}: {int(info.get(field, 0)) / COIN:,.0f}')
        except Exception as e:
            _log(f'  (could not read reserve info: {e})')
