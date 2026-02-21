"""ZephyrClient — high-level API matching wallet CLI commands."""

import sys
import time

import requests

from .config import load_config
from .rpc import Wallet, Daemon
from .formatting import COIN

# Maps (from_asset, to_asset) -> (method_name, source_asset, dest_asset)
CONVERSIONS = {
    ('ZPH', 'ZSD'): ('mint_stable',    'ZPH', 'ZSD'),
    ('ZSD', 'ZPH'): ('redeem_stable',  'ZSD', 'ZPH'),
    ('ZPH', 'ZRS'): ('mint_reserve',   'ZPH', 'ZRS'),
    ('ZRS', 'ZPH'): ('redeem_reserve', 'ZRS', 'ZPH'),
    ('ZSD', 'ZYS'): ('mint_yield',     'ZSD', 'ZYS'),
    ('ZYS', 'ZSD'): ('redeem_yield',   'ZYS', 'ZSD'),
}

# Maps asset to the right same-asset transfer method
ASSET_TRANSFER = {
    'ZPH': 'transfer',
    'ZSD': 'stable_transfer',
    'ZRS': 'reserve_transfer',
    'ZYS': 'yield_transfer',
}


class ZephyrClient:
    def __init__(self, config=None, config_path=None):
        cfg = load_config(config=config, config_path=config_path)

        daemon_cfg = cfg['daemon']
        self.daemon = Daemon(host=daemon_cfg['host'], port=daemon_cfg['port'])

        self.oracle_url = 'http://{}:{}'.format(
            cfg['oracle']['host'], cfg['oracle']['port'])

        self.wallets = {}
        self.wallet_info = {}
        for name, wcfg in cfg.get('wallets', {}).items():
            self.wallets[name] = Wallet(host=daemon_cfg.get('host', '127.0.0.1'),
                                        port=wcfg['port'])
            self.wallet_info[name] = wcfg

    def _get_wallet(self, name):
        if name not in self.wallets:
            raise ValueError(f'Unknown wallet: {name!r}  (available: {", ".join(sorted(self.wallets))})')
        return self.wallets[name]

    def _amount_to_atomic(self, amount):
        """Convert a float/int amount to atomic units."""
        return int(round(float(amount) * COIN))

    def _do_transfer(self, wallet_name, address, amount, source_asset, dest_asset):
        """Core transfer: sends amount (float) from wallet to address."""
        w = self._get_wallet(wallet_name)
        atomic = self._amount_to_atomic(amount)
        destinations = [{'amount': atomic, 'address': address}]
        return w.transfer(destinations, source_asset=source_asset, destination_asset=dest_asset)

    # ── Wallet CLI commands (same names) ──────────────────────────────────

    def transfer(self, wallet, address, amount):
        """transfer: ZPH -> ZPH (send ZEPH to address)"""
        return self._do_transfer(wallet, address, amount, 'ZPH', 'ZPH')

    def mint_stable(self, wallet, address, amount):
        """mint_stable: ZPH -> ZSD"""
        return self._do_transfer(wallet, address, amount, 'ZPH', 'ZSD')

    def redeem_stable(self, wallet, address, amount):
        """redeem_stable: ZSD -> ZPH"""
        return self._do_transfer(wallet, address, amount, 'ZSD', 'ZPH')

    def stable_transfer(self, wallet, address, amount):
        """stable_transfer: ZSD -> ZSD"""
        return self._do_transfer(wallet, address, amount, 'ZSD', 'ZSD')

    def mint_reserve(self, wallet, address, amount):
        """mint_reserve: ZPH -> ZRS"""
        return self._do_transfer(wallet, address, amount, 'ZPH', 'ZRS')

    def redeem_reserve(self, wallet, address, amount):
        """redeem_reserve: ZRS -> ZPH"""
        return self._do_transfer(wallet, address, amount, 'ZRS', 'ZPH')

    def reserve_transfer(self, wallet, address, amount):
        """reserve_transfer: ZRS -> ZRS"""
        return self._do_transfer(wallet, address, amount, 'ZRS', 'ZRS')

    def mint_yield(self, wallet, address, amount):
        """mint_yield: ZSD -> ZYS"""
        return self._do_transfer(wallet, address, amount, 'ZSD', 'ZYS')

    def redeem_yield(self, wallet, address, amount):
        """redeem_yield: ZYS -> ZSD"""
        return self._do_transfer(wallet, address, amount, 'ZYS', 'ZSD')

    def yield_transfer(self, wallet, address, amount):
        """yield_transfer: ZYS -> ZYS"""
        return self._do_transfer(wallet, address, amount, 'ZYS', 'ZYS')

    # ── Convenience helpers ───────────────────────────────────────────────

    def convert(self, wallet, amount, from_asset, to_asset):
        """Self-transfer for conversions. Resolves to the right mint/redeem call."""
        from_asset = from_asset.upper()
        to_asset = to_asset.upper()
        key = (from_asset, to_asset)
        if key not in CONVERSIONS:
            raise ValueError(f'No conversion path from {from_asset} to {to_asset}')
        _, src, dst = CONVERSIONS[key]
        address = self.get_address(wallet)
        return self._do_transfer(wallet, address, amount, src, dst)

    def send(self, from_wallet, to_wallet, amount, asset='ZPH'):
        """Named-wallet-to-named-wallet transfer. Picks the right method for asset type."""
        asset = asset.upper()
        if asset not in ASSET_TRANSFER:
            raise ValueError(f'Unknown asset: {asset!r}')
        address = self.get_address(to_wallet)
        method_name = ASSET_TRANSFER[asset]
        method = getattr(self, method_name)
        return method(from_wallet, address, amount)

    # ── Info commands ─────────────────────────────────────────────────────

    def balances(self, wallet=None):
        """All wallets' balances (all assets), or single wallet if specified."""
        names = [wallet] if wallet else sorted(self.wallets)
        result = {}
        for name in names:
            w = self._get_wallet(name)
            w.refresh()
            bal = w.get_balance(all_assets=True)
            per_asset = {}
            if 'balances' in bal and bal['balances']:
                for entry in bal['balances']:
                    asset = entry.get('asset_type', 'ZPH')
                    per_asset[asset] = entry.get('unlocked_balance', 0)
            elif 'balance' in bal:
                per_asset['ZPH'] = bal.get('unlocked_balance', bal.get('balance', 0))
            result[name] = per_asset
        return result

    def reserve_info(self):
        return self.daemon.get_reserve_info()

    def yield_info(self):
        return self.daemon.get_yield_info()

    def supply_info(self):
        return self.daemon.get_supply_info()

    def get_address(self, wallet):
        """Get primary address for a named wallet."""
        w = self._get_wallet(wallet)
        res = w.get_address()
        return res.address

    def refresh(self, wallet):
        """Refresh a wallet."""
        w = self._get_wallet(wallet)
        return w.refresh()

    # ── Daemon operations ──────────────────────────────────────────────────

    def height(self):
        """Get current blockchain height."""
        info = self.daemon.get_info()
        return info.height

    def info(self):
        """Get daemon info (height, difficulty, connections, etc.)."""
        return self.daemon.get_info()

    def wait_for_height(self, target, refresh_wallets=True, poll_interval=1, stream=True):
        """Block until chain reaches target height. Optionally refresh wallets."""
        target = int(target)
        while True:
            h = self.height()
            if h >= target:
                if stream:
                    print(f'Height {h} reached')
                if refresh_wallets:
                    for w in self.wallets.values():
                        try:
                            w.refresh()
                        except Exception:
                            pass
                return h
            if stream:
                sys.stdout.write(f'\rWaiting for height {target}... ({h})')
                sys.stdout.flush()
            time.sleep(poll_interval)

    def mine_start(self, wallet='miner', threads=2):
        """Start mining to a named wallet's address."""
        addr = self.get_address(wallet)
        return self.daemon.start_mining(addr, threads_count=threads)

    def mine_stop(self):
        """Stop mining."""
        return self.daemon.stop_mining()

    def rescan(self, wallet=None):
        """Rescan blockchain for wallet(s). None or 'all' rescans all wallets."""
        if wallet and wallet != 'all':
            names = [wallet]
        else:
            names = sorted(self.wallets)
        results = {}
        for name in names:
            w = self._get_wallet(name)
            w.rescan_blockchain()
            w.refresh()
            results[name] = 'ok'
        return results

    def pop_blocks(self, count):
        """Pop N blocks from the blockchain."""
        return self.daemon.pop_blocks(int(count))

    # ── Oracle (devnet only) ──────────────────────────────────────────────

    def get_price(self):
        """Get current oracle spot price in USD."""
        resp = requests.get(f'{self.oracle_url}/status', timeout=5)
        data = resp.json()
        spot = data.get('spot', 0)
        return spot / COIN

    def set_price(self, usd_price):
        """Set oracle spot price (USD float, e.g. 1.50)."""
        atomic = int(round(float(usd_price) * COIN))
        resp = requests.post(f'{self.oracle_url}/set-price',
                             json={'spot': atomic}, timeout=5)
        return resp.json()
