"""Extended Wallet/Daemon RPC classes with Zephyr multi-asset support."""

import sys
import os

# Add upstream python-rpc to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..', 'utils', 'python-rpc'))

from framework.wallet import Wallet as _UpstreamWallet
from framework.daemon import Daemon as _UpstreamDaemon


class Wallet(_UpstreamWallet):
    """Zephyr wallet RPC — extends upstream with source_asset/destination_asset."""

    def __init__(self, host='127.0.0.1', port=18090):
        super().__init__(host=host, port=port)

    def transfer(self, destinations, source_asset='ZPH', destination_asset='ZPH',
                 account_index=0, priority=0, ring_size=0, get_tx_key=True,
                 do_not_relay=False, get_tx_hex=False):
        req = {
            'method': 'transfer',
            'params': {
                'destinations': destinations,
                'source_asset': source_asset,
                'destination_asset': destination_asset,
                'account_index': account_index,
                'priority': priority,
                'ring_size': ring_size,
                'get_tx_key': get_tx_key,
                'do_not_relay': do_not_relay,
                'get_tx_hex': get_tx_hex,
            },
            'jsonrpc': '2.0',
            'id': '0',
        }
        return self.rpc.send_json_rpc_request(req)

    def get_balance(self, account_index=0, address_indices=None, all_accounts=False,
                    strict=False, all_assets=False):
        req = {
            'method': 'get_balance',
            'params': {
                'account_index': account_index,
                'address_indices': address_indices or [],
                'all_accounts': all_accounts,
                'strict': strict,
                'all_assets': all_assets,
            },
            'jsonrpc': '2.0',
            'id': '0',
        }
        return self.rpc.send_json_rpc_request(req)


class Daemon(_UpstreamDaemon):
    """Zephyr daemon RPC — adds reserve/yield/supply info."""

    def __init__(self, host='127.0.0.1', port=18180):
        super().__init__(host=host, port=port)

    def get_reserve_info(self):
        req = {
            'method': 'get_reserve_info',
            'params': {},
            'jsonrpc': '2.0',
            'id': '0',
        }
        return self.rpc.send_json_rpc_request(req)

    def get_yield_info(self):
        req = {
            'method': 'get_yield_info',
            'params': {},
            'jsonrpc': '2.0',
            'id': '0',
        }
        return self.rpc.send_json_rpc_request(req)

    def get_supply_info(self):
        req = {
            'method': 'get_supply_info',
            'params': {},
            'jsonrpc': '2.0',
            'id': '0',
        }
        return self.rpc.send_json_rpc_request(req)
