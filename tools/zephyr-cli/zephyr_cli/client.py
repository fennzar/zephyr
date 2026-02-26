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

        daemon2_cfg = cfg.get('daemon2', {'host': daemon_cfg['host'], 'port': 47867})
        self.daemon2 = Daemon(host=daemon2_cfg['host'], port=daemon2_cfg['port'])

        self.oracle_url = 'http://{}:{}'.format(
            cfg['oracle']['host'], cfg['oracle']['port'])

        self.wallets = {}
        self.wallet_info = {}
        for name, wcfg in cfg.get('wallets', {}).items():
            wallet_host = wcfg.get('host', daemon_cfg.get('host', '127.0.0.1'))
            self.wallets[name] = Wallet(host=wallet_host, port=wcfg['port'])
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

    def wait_for_height(self, target, refresh_wallets=True, poll_interval=0.1, stream=True):
        """Block until chain reaches target height. Optionally refresh wallets."""
        target = int(target)
        last_print = 0.0
        while True:
            h = self.height()
            if h >= target:
                if stream:
                    sys.stdout.write(f'\rHeight {h} reached{" " * 20}\n')
                    sys.stdout.flush()
                if refresh_wallets:
                    for w in self.wallets.values():
                        try:
                            w.refresh()
                        except Exception:
                            pass
                return h
            now = time.monotonic()
            if stream and (now - last_print) >= 0.5:
                sys.stdout.write(f'\rWaiting for height {target}... ({h})')
                sys.stdout.flush()
                last_print = now
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

    def height2(self):
        """Get blockchain height from node2."""
        info = self.daemon2.get_info()
        return info.height

    def pop_blocks2(self, count):
        """Pop N blocks from node2."""
        return self.daemon2.pop_blocks(int(count))

    def wait_for_daemons(self, timeout=30):
        """Wait until both daemons respond."""
        deadline = time.monotonic() + timeout
        ready = [False, False]
        while time.monotonic() < deadline:
            if not ready[0]:
                try:
                    self.daemon.get_info()
                    ready[0] = True
                except Exception:
                    pass
            if not ready[1]:
                try:
                    self.daemon2.get_info()
                    ready[1] = True
                except Exception:
                    pass
            if all(ready):
                return True
            time.sleep(1)
        raise TimeoutError(f'Daemons not ready after {timeout}s (node1={ready[0]}, node2={ready[1]})')

    # ── Wallet management ─────────────────────────────────────────────────

    def create_wallet(self, name, password=''):
        """Create a new wallet on the wallet RPC for `name`. Opens if already exists."""
        w = self._get_wallet(name)
        try:
            w.create_wallet(filename=name, password=password, language='English')
        except Exception:
            w.open_wallet(filename=name, password=password)

    def open_wallet(self, name, password=''):
        """Open an existing wallet on the wallet RPC for `name`."""
        w = self._get_wallet(name)
        w.open_wallet(filename=name, password=password)

    def open_all_wallets(self, password='', timeout=30):
        """Open all configured wallets with retry."""
        results = {}
        for name in sorted(self.wallets):
            w = self._get_wallet(name)
            deadline = time.monotonic() + timeout
            opened = False
            while time.monotonic() < deadline:
                try:
                    w.rpc.send_json_rpc_request({'method': 'get_version', 'params': {}, 'jsonrpc': '2.0', 'id': '0'})
                    # RPC ready, try to open
                    try:
                        w.open_wallet(filename=name, password=password)
                    except Exception:
                        pass  # Already open or doesn't exist
                    opened = True
                    break
                except Exception:
                    time.sleep(1)
            results[name] = 'ok' if opened else 'timeout'
        return results

    def restore_wallet(self, name, address, spendkey, viewkey,
                       password='', restore_height=0):
        """Restore a wallet from keys on the wallet RPC for `name`."""
        w = self._get_wallet(name)
        w.generate_from_keys(filename=name, address=address,
                             spendkey=spendkey, viewkey=viewkey,
                             password=password, restore_height=restore_height)

    def close_wallet(self, name):
        """Close the wallet file on the RPC for `name`."""
        w = self._get_wallet(name)
        w.close_wallet()

    def create_subaddress(self, name, label=''):
        """Create a new subaddress for wallet `name`."""
        w = self._get_wallet(name)
        return w.create_address(label=label)

    # ── Daemon extras ───────────────────────────────────────────────────

    def flush_txpool(self):
        """Flush the transaction pool."""
        return self.daemon.flush_txpool()

    def start_mining(self, address, threads=2):
        """Start mining to a raw address (bypasses wallet lookup)."""
        return self.daemon.start_mining(address, threads_count=threads)

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

    def oracle_status(self):
        """Get full oracle status (spot, MA, mode, etc.)."""
        resp = requests.get(f'{self.oracle_url}/status', timeout=5)
        return resp.json()

    def oracle_set_ma(self, usd_price):
        """Set oracle moving average (USD float)."""
        atomic = int(round(float(usd_price) * COIN))
        resp = requests.post(f'{self.oracle_url}/set-ma',
                             json={'moving_average': atomic}, timeout=5)
        return resp.json()

    def oracle_set_ma_mode(self, mode, alpha=0.1):
        """Set oracle MA mode (spot|manual|ema|mirror)."""
        resp = requests.post(f'{self.oracle_url}/set-ma-mode',
                             json={'mode': mode, 'ema_alpha': float(alpha)}, timeout=5)
        return resp.json()

    def oracle_supply_sync(self, mode='sync'):
        """Enable/disable supply sync mode."""
        resp = requests.post(f'{self.oracle_url}/set-supply-mode',
                             json={'mode': mode}, timeout=5)
        return resp.json()

    def oracle_supply_status(self):
        """Get supply sync status."""
        resp = requests.get(f'{self.oracle_url}/supply-status', timeout=5)
        return resp.json()
