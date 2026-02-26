"""CLI interface — argparse for one-shot commands, cmd.Cmd for interactive shell."""

import argparse
import cmd
import json
import sys

from .client import ZephyrClient
from .formatting import (
    format_balances_table, format_reserve_info, format_daemon_info, format_amount,
)

# Commands that follow the pattern: <cmd> <wallet> <address> <amount>
TRANSFER_COMMANDS = [
    'transfer', 'mint_stable', 'redeem_stable', 'stable_transfer',
    'mint_reserve', 'redeem_reserve', 'reserve_transfer',
    'mint_yield', 'redeem_yield', 'yield_transfer',
]

# Asset mapping descriptions for help
COMMAND_DESC = {
    'transfer':         'ZPH -> ZPH  (send ZEPH)',
    'mint_stable':      'ZPH -> ZSD  (convert ZEPH to ZSD)',
    'redeem_stable':    'ZSD -> ZPH  (convert ZSD to ZEPH)',
    'stable_transfer':  'ZSD -> ZSD  (send ZSD)',
    'mint_reserve':     'ZPH -> ZRS  (convert ZEPH to ZRS)',
    'redeem_reserve':   'ZRS -> ZPH  (convert ZRS to ZEPH)',
    'reserve_transfer': 'ZRS -> ZRS  (send ZRS)',
    'mint_yield':       'ZSD -> ZYS  (convert ZSD to ZYS)',
    'redeem_yield':     'ZYS -> ZSD  (convert ZYS to ZSD)',
    'yield_transfer':   'ZYS -> ZYS  (send ZYS)',
}


def _print_tx_result(result, label=None):
    """Print a transfer result."""
    if label:
        print(label)
    if hasattr(result, 'tx_hash'):
        print(f'TX: {result.tx_hash}')
    elif hasattr(result, 'tx_hash_list'):
        for h in result.tx_hash_list:
            print(f'TX: {h}')
    else:
        print(f'Result: {dict(result) if hasattr(result, "keys") else result}')


def build_parser():
    parser = argparse.ArgumentParser(
        prog='zephyr-cli',
        description='Zephyr devnet CLI — wallet commands and multi-wallet management',
    )
    parser.add_argument('-c', '--config', help='Path to config JSON file')

    sub = parser.add_subparsers(dest='command')

    # Transfer commands: <cmd> <wallet> <address> <amount>
    for cmd_name in TRANSFER_COMMANDS:
        p = sub.add_parser(cmd_name, help=COMMAND_DESC[cmd_name])
        p.add_argument('wallet', help='Wallet name')
        p.add_argument('address', help='Destination address')
        p.add_argument('amount', type=float, help='Amount')

    # convert <wallet> <amount> <from> <to>
    p = sub.add_parser('convert', help='Self-transfer conversion (mint/redeem)')
    p.add_argument('wallet', help='Wallet name')
    p.add_argument('amount', type=float, help='Amount')
    p.add_argument('from_asset', help='Source asset (ZPH, ZSD, ZRS, ZYS)')
    p.add_argument('to_asset', help='Destination asset')

    # send <from_wallet> <to_wallet> <amount> [asset]
    p = sub.add_parser('send', help='Named-wallet-to-named-wallet transfer')
    p.add_argument('from_wallet', help='Source wallet name')
    p.add_argument('to_wallet', help='Destination wallet name')
    p.add_argument('amount', type=float, help='Amount')
    p.add_argument('asset', nargs='?', default='ZPH', help='Asset type (default: ZPH)')

    # balances [wallet]
    p = sub.add_parser('balances', help='Show wallet balances')
    p.add_argument('wallet', nargs='?', help='Wallet name (all if omitted)')

    # address <wallet>
    p = sub.add_parser('address', help='Show wallet address')
    p.add_argument('wallet', help='Wallet name')

    # refresh <wallet>
    p = sub.add_parser('refresh', help='Refresh wallet')
    p.add_argument('wallet', help='Wallet name')

    # Info commands
    sub.add_parser('reserve_info', help='Show reserve info')
    sub.add_parser('yield_info', help='Show yield info')
    sub.add_parser('supply_info', help='Show supply info')

    # price [value]
    p = sub.add_parser('price', help='Get/set oracle price')
    p.add_argument('value', nargs='?', type=float, help='USD price to set (omit to get)')

    # ── Daemon operations ─────────────────────────────────────────────

    # height [--all]
    p = sub.add_parser('height', help='Show current blockchain height')
    p.add_argument('--all', action='store_true', help='Show both node1 and node2 heights')

    # wait <n>
    p = sub.add_parser('wait', help='Wait until chain reaches height N')
    p.add_argument('target', type=int, help='Target block height')

    # mine start|stop
    p = sub.add_parser('mine', help='Start or stop mining')
    p.add_argument('action', choices=['start', 'stop'], help='start or stop')
    p.add_argument('--wallet', default='miner', help='Wallet to mine to (default: miner)')
    p.add_argument('--threads', type=int, default=2, help='Mining threads (default: 2)')

    # rescan [wallet|all]
    p = sub.add_parser('rescan', help='Rescan blockchain for wallet(s)')
    p.add_argument('wallet', nargs='?', default='all', help='Wallet name or "all" (default: all)')

    # info
    sub.add_parser('info', help='Show daemon info')

    # pop <blocks> [--all]
    p = sub.add_parser('pop', help='Pop N blocks from the chain')
    p.add_argument('count', type=int, help='Number of blocks to pop')
    p.add_argument('--all', action='store_true', help='Pop from both node1 and node2')

    # flush-txpool
    sub.add_parser('flush-txpool', help='Flush the transaction pool')

    # wait-daemons
    p = sub.add_parser('wait-daemons', help='Wait until both daemons are ready')
    p.add_argument('--timeout', type=int, default=30, help='Timeout in seconds (default: 30)')

    # ── Wallet management ────────────────────────────────────────────
    wallet_p = sub.add_parser('wallet', help='Wallet management')
    wallet_sub = wallet_p.add_subparsers(dest='wallet_cmd')

    p = wallet_sub.add_parser('create', help='Create or open a wallet')
    p.add_argument('name', help='Wallet name (must exist in config)')
    p.add_argument('--password', default='')

    p = wallet_sub.add_parser('open', help='Open an existing wallet')
    p.add_argument('name')
    p.add_argument('--password', default='')

    p = wallet_sub.add_parser('restore', help='Restore wallet from keys')
    p.add_argument('name')
    p.add_argument('--address', required=True)
    p.add_argument('--spendkey', required=True)
    p.add_argument('--viewkey', required=True)
    p.add_argument('--password', default='')
    p.add_argument('--restore-height', type=int, default=0)

    p = wallet_sub.add_parser('close', help='Close a wallet')
    p.add_argument('name')

    # ── Oracle subcommands ─────────────────────────────────────────
    oracle_p = sub.add_parser('oracle', help='Oracle management (devnet)')
    oracle_sub = oracle_p.add_subparsers(dest='oracle_cmd')

    oracle_sub.add_parser('status', help='Show full oracle state')

    p = oracle_sub.add_parser('ma', help='Set oracle moving average')
    p.add_argument('value', type=float, help='USD price for moving average')

    p = oracle_sub.add_parser('ma-mode', help='Set MA tracking mode')
    p.add_argument('mode', choices=['spot', 'manual', 'ema', 'mirror'], help='MA mode')
    p.add_argument('--alpha', type=float, default=0.1, help='EMA alpha (default: 0.1)')

    oracle_sub.add_parser('supply-sync', help='Enable supply sync mode')
    oracle_sub.add_parser('supply-status', help='Show supply sync state')

    # ── Devnet lifecycle ─────────────────────────────────────────────
    devnet_p = sub.add_parser('devnet', help='Devnet lifecycle management')
    devnet_sub = devnet_p.add_subparsers(dest='devnet_cmd')

    p = devnet_sub.add_parser('init', help='Bootstrap devnet (gov/miner/test + mint + checkpoint)')
    p.add_argument('--oracle-price', type=float, default=2.0)
    p.add_argument('--mode', choices=['custom', 'mirror'], default='custom')
    p.add_argument('--target-rr', type=float, default=7.0)
    p.add_argument('--zsd-limit', type=int, default=450000)
    p.add_argument('--checkpoint-file', default=None)
    p.add_argument('--mining-threads', type=int, default=2)

    p = devnet_sub.add_parser('snapshot', help='Save LMDB snapshot')
    p.add_argument('name', nargs='?', default='default')
    p.add_argument('--snapshot-dir', default=None)

    p = devnet_sub.add_parser('reset', help='Restore LMDB snapshot')
    p.add_argument('name', nargs='?', default='default')
    p.add_argument('--snapshot-dir', default=None)

    # ── Setup state ──────────────────────────────────────────────────
    p = sub.add_parser('setup-state', help='Run devnet minting sequence')
    p.add_argument('--mode', choices=['custom', 'mirror'], default='custom')
    p.add_argument('--target-rr', type=float, default=7.0)
    p.add_argument('--zsd-limit', type=int, default=450000)
    p.add_argument('--oracle-price', type=float, default=None)

    return parser


def run_command(client, args):
    """Execute a parsed command. Returns True if handled."""
    if args.command in TRANSFER_COMMANDS:
        method = getattr(client, args.command)
        result = method(args.wallet, args.address, args.amount)
        desc = COMMAND_DESC[args.command]
        _print_tx_result(result, f'{args.command}: {format_amount(args.amount)} {desc.split()[0]} ({desc})')
        return True

    if args.command == 'convert':
        result = client.convert(args.wallet, args.amount, args.from_asset, args.to_asset)
        _print_tx_result(result,
            f'convert: {format_amount(args.amount)} {args.from_asset.upper()} -> {args.to_asset.upper()} in {args.wallet}')
        return True

    if args.command == 'send':
        result = client.send(args.from_wallet, args.to_wallet, args.amount, args.asset)
        _print_tx_result(result,
            f'Transferring {format_amount(args.amount)} {args.asset.upper()}: {args.from_wallet} -> {args.to_wallet}')
        return True

    if args.command == 'balances':
        bals = client.balances(args.wallet)
        print(format_balances_table(bals))
        return True

    if args.command == 'address':
        addr = client.get_address(args.wallet)
        print(f'{args.wallet}: {addr}')
        return True

    if args.command == 'refresh':
        client.refresh(args.wallet)
        print(f'{args.wallet}: refreshed')
        return True

    if args.command == 'reserve_info':
        info = client.reserve_info()
        print('Reserve Info:')
        print(format_reserve_info(dict(info)))
        return True

    if args.command == 'yield_info':
        info = client.yield_info()
        print('Yield Info:')
        print(format_reserve_info(dict(info)))
        return True

    if args.command == 'supply_info':
        info = client.supply_info()
        print('Supply Info:')
        print(format_reserve_info(dict(info)))
        return True

    if args.command == 'price':
        if args.value is not None:
            client.set_price(args.value)
            print(f'Oracle price set to ${args.value:.2f}')
        else:
            price = client.get_price()
            print(f'Oracle: ${price:.2f}')
        return True

    if args.command == 'oracle':
        if args.oracle_cmd == 'status':
            data = client.oracle_status()
            spot = data.get('spot', 0) / 1e12
            ma = data.get('moving_average', 0) / 1e12
            mode = data.get('ma_mode', 'unknown')
            print(f'Oracle Status:')
            print(f'  Spot:  ${spot:.4f}')
            print(f'  MA:    ${ma:.4f}')
            print(f'  Mode:  {mode}')
            # Print any other fields
            for k, v in data.items():
                if k not in ('spot', 'moving_average', 'ma_mode'):
                    print(f'  {k}: {v}')
        elif args.oracle_cmd == 'ma':
            client.oracle_set_ma(args.value)
            print(f'Oracle MA set to ${args.value:.2f}')
        elif args.oracle_cmd == 'ma-mode':
            client.oracle_set_ma_mode(args.mode, alpha=args.alpha)
            print(f'Oracle MA mode set to {args.mode} (alpha={args.alpha})')
        elif args.oracle_cmd == 'supply-sync':
            client.oracle_supply_sync()
            print('Supply sync enabled')
        elif args.oracle_cmd == 'supply-status':
            data = client.oracle_supply_status()
            print(json.dumps(data, indent=2))
        else:
            print('Usage: oracle {status|ma|ma-mode|supply-sync|supply-status} ...')
        return True

    if args.command == 'height':
        if getattr(args, 'all', False):
            try:
                h1 = client.height()
                print(f'node1: {h1}')
            except Exception as e:
                print(f'node1: error ({e})', file=sys.stderr)
            try:
                h2 = client.height2()
                print(f'node2: {h2}')
            except Exception as e:
                print(f'node2: error ({e})', file=sys.stderr)
        else:
            h = client.height()
            print(h)
        return True

    if args.command == 'wait':
        client.wait_for_height(args.target)
        return True

    if args.command == 'mine':
        if args.action == 'start':
            client.mine_start(wallet=args.wallet, threads=args.threads)
            print(f'Mining started (wallet={args.wallet}, threads={args.threads})')
        else:
            client.mine_stop()
            print('Mining stopped')
        return True

    if args.command == 'rescan':
        results = client.rescan(args.wallet)
        for name in results:
            print(f'{name}: rescanned')
        return True

    if args.command == 'info':
        info = client.info()
        print(format_daemon_info(dict(info)))
        return True

    if args.command == 'pop':
        if getattr(args, 'all', False):
            try:
                client.pop_blocks(args.count)
                print(f'node1: popped {args.count} blocks')
            except Exception as e:
                print(f'node1: error ({e})', file=sys.stderr)
            try:
                client.pop_blocks2(args.count)
                print(f'node2: popped {args.count} blocks')
            except Exception as e:
                print(f'node2: error ({e})', file=sys.stderr)
        else:
            client.pop_blocks(args.count)
            print(f'Popped {args.count} blocks')
        return True

    if args.command == 'flush-txpool':
        client.flush_txpool()
        print('Transaction pool flushed')
        return True

    if args.command == 'wait-daemons':
        client.wait_for_daemons(timeout=args.timeout)
        print('Both daemons ready')
        return True

    if args.command == 'wallet':
        if args.wallet_cmd == 'create':
            client.create_wallet(args.name, password=args.password)
            print(f'Wallet {args.name}: created/opened')
        elif args.wallet_cmd == 'open':
            if args.name == 'all':
                results = client.open_all_wallets(password=args.password)
                for name, status in results.items():
                    print(f'  {name}: {status}')
                print(f'Wallets opened ({len(results)})')
            else:
                client.open_wallet(args.name, password=args.password)
                print(f'Wallet {args.name}: opened')
        elif args.wallet_cmd == 'restore':
            client.restore_wallet(args.name, address=args.address,
                                  spendkey=args.spendkey, viewkey=args.viewkey,
                                  password=args.password,
                                  restore_height=args.restore_height)
            print(f'Wallet {args.name}: restored from keys')
        elif args.wallet_cmd == 'close':
            client.close_wallet(args.name)
            print(f'Wallet {args.name}: closed')
        else:
            print('Usage: wallet {create|open|restore|close} ...')
        return True

    if args.command == 'setup-state':
        from .setup_state import SetupState
        ss = SetupState(client, mode=args.mode, target_rr=args.target_rr,
                        zsd_mint_limit=args.zsd_limit, oracle_price=args.oracle_price)
        ss.run()
        return True

    if args.command == 'devnet':
        from .devnet import run_devnet_command
        run_devnet_command(client, args)
        return True

    return False


class ZephyrShell(cmd.Cmd):
    """Interactive Zephyr CLI shell."""

    intro = 'Zephyr devnet CLI. Type "help" for commands, "quit" to exit.'
    prompt = 'zephyr> '

    def __init__(self, client):
        super().__init__()
        self.client = client

    def _parse_and_run(self, command, arg_string):
        """Parse args for a command and run it."""
        parser = build_parser()
        try:
            args = parser.parse_args([command] + arg_string.split())
            run_command(self.client, args)
        except SystemExit:
            pass
        except Exception as e:
            print(f'Error: {e}')

    # Transfer commands
    def do_transfer(self, arg):        self._parse_and_run('transfer', arg)
    def do_mint_stable(self, arg):     self._parse_and_run('mint_stable', arg)
    def do_redeem_stable(self, arg):   self._parse_and_run('redeem_stable', arg)
    def do_stable_transfer(self, arg): self._parse_and_run('stable_transfer', arg)
    def do_mint_reserve(self, arg):    self._parse_and_run('mint_reserve', arg)
    def do_redeem_reserve(self, arg):  self._parse_and_run('redeem_reserve', arg)
    def do_reserve_transfer(self, arg):self._parse_and_run('reserve_transfer', arg)
    def do_mint_yield(self, arg):      self._parse_and_run('mint_yield', arg)
    def do_redeem_yield(self, arg):    self._parse_and_run('redeem_yield', arg)
    def do_yield_transfer(self, arg):  self._parse_and_run('yield_transfer', arg)

    # Help text for transfer commands
    for _cmd in TRANSFER_COMMANDS:
        locals()[f'help_{_cmd}'] = (lambda c: lambda self: print(
            f'{c} <wallet> <address> <amount>  — {COMMAND_DESC[c]}'))(_cmd)

    # Convenience
    def do_convert(self, arg):
        """convert <wallet> <amount> <from_asset> <to_asset> — Self-transfer conversion"""
        self._parse_and_run('convert', arg)

    def do_send(self, arg):
        """send <from_wallet> <to_wallet> <amount> [asset] — Wallet-to-wallet transfer"""
        self._parse_and_run('send', arg)

    # Info
    def do_balances(self, arg):
        """balances [wallet] — Show all wallet balances"""
        self._parse_and_run('balances', arg)

    def do_address(self, arg):
        """address <wallet> — Show wallet address"""
        self._parse_and_run('address', arg)

    def do_refresh(self, arg):
        """refresh <wallet> — Refresh wallet"""
        self._parse_and_run('refresh', arg)

    def do_reserve_info(self, arg):
        """reserve_info — Show reserve info"""
        self._parse_and_run('reserve_info', arg)

    def do_yield_info(self, arg):
        """yield_info — Show yield info"""
        self._parse_and_run('yield_info', arg)

    def do_supply_info(self, arg):
        """supply_info — Show supply info"""
        self._parse_and_run('supply_info', arg)

    def do_price(self, arg):
        """price [value] — Get or set oracle price"""
        self._parse_and_run('price', arg)

    def do_oracle(self, arg):
        """oracle {status|ma|ma-mode|supply-sync|supply-status} — Oracle management"""
        self._parse_and_run('oracle', arg)

    # Daemon operations
    def do_height(self, arg):
        """height — Show current blockchain height"""
        self._parse_and_run('height', arg)

    def do_wait(self, arg):
        """wait <n> — Wait until chain reaches height N"""
        self._parse_and_run('wait', arg)

    def do_mine(self, arg):
        """mine start|stop [--wallet W] [--threads N] — Start or stop mining"""
        self._parse_and_run('mine', arg)

    def do_rescan(self, arg):
        """rescan [wallet|all] — Rescan blockchain for wallet(s)"""
        self._parse_and_run('rescan', arg)

    def do_info(self, arg):
        """info — Show daemon info"""
        self._parse_and_run('info', arg)

    def do_pop(self, arg):
        """pop <n> — Pop N blocks from the chain"""
        self._parse_and_run('pop', arg)

    def do_flush_txpool(self, arg):
        """flush-txpool — Flush the transaction pool"""
        self._parse_and_run('flush-txpool', arg)

    def do_wait_daemons(self, arg):
        """wait-daemons [--timeout N] — Wait until both daemons are ready"""
        self._parse_and_run('wait-daemons', arg)

    def do_wallet(self, arg):
        """wallet {create|open|restore|close} ... — Wallet management"""
        self._parse_and_run('wallet', arg)

    def do_quit(self, arg):
        """Exit the shell"""
        return True

    def do_exit(self, arg):
        """Exit the shell"""
        return True

    do_EOF = do_quit

    def emptyline(self):
        return False


def main():
    if len(sys.argv) > 1:
        # Non-interactive mode
        parser = build_parser()
        args = parser.parse_args()
        if not args.command:
            parser.print_help()
            sys.exit(1)
        client = ZephyrClient(config_path=args.config)
        try:
            if not run_command(client, args):
                parser.print_help()
                sys.exit(1)
        except Exception as e:
            print(f'Error: {e}', file=sys.stderr)
            sys.exit(1)
    else:
        # Interactive shell
        client = ZephyrClient()
        ZephyrShell(client).cmdloop()


if __name__ == '__main__':
    main()
