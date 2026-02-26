"""Devnet lifecycle management — init, snapshot, reset."""

import json
import os
import time

from .setup_state import SetupState


def _log(msg):
    print(msg, flush=True)


# Hardcoded deterministic keys — DEVNET ONLY
GOV_ADDRESS = 'ZPHSjqHRP2cPUoxHrVXe8K6rjdDdA9JF8WL549DrkDVtiYYbkfkJSvc4bQ6iXVb11Z3hcGETaNPgiMG5wu3fCPjviLk4Nu69oJy'
GOV_SPEND_KEY = 'dcf91a5b3e9913e0b78aa9460636f61ac9df37bbb003d795a555553214c83e09'
GOV_VIEW_KEY = '0ad41f7f73ee411387fbcf722364db676022f08c54fa4bb4708b6eec8c6b1a00'


class DevnetInit:
    """Bootstrap a fresh devnet: wallets, mining, minting, checkpoint.

    Always creates gov (restored from keys) + miner + test wallets.
    Consumer-specific wallets (bridge, engine, cex) are NOT created here.
    """

    def __init__(self, client, oracle_price=2.0, mining_threads=2,
                 setup_mode='custom', target_rr=7.0, zsd_limit=450000,
                 checkpoint_file=None):
        self.client = client
        self.oracle_price = oracle_price
        self.mining_threads = mining_threads
        self.setup_mode = setup_mode
        self.target_rr = target_rr
        self.zsd_limit = zsd_limit
        self.checkpoint_file = checkpoint_file

    def run(self):
        _log('=========================================')
        _log('  DEVNET Init - Bootstrap Sequence')
        _log('=========================================')
        _log('')

        self._set_oracle_price()
        self._wait_for_services()
        self._restore_gov_wallet()
        self._create_wallets()
        self._start_mining()
        self._wait_governance_unlock()
        self._run_setup_state()
        self._stop_mining()
        self._save_checkpoint()

        height = self.client.height()
        _log('')
        _log('=========================================')
        _log('  DEVNET Init Complete!')
        _log(f'  Mode:         {self.setup_mode}')
        _log(f'  Chain height: {height}')
        _log('  Mining: stopped')
        _log('=========================================')

    def _set_oracle_price(self):
        _log(f'--- Step 1: Setting oracle price to ${self.oracle_price:.2f} ---')
        self.client.set_price(self.oracle_price)
        _log('')

    def _wait_for_services(self):
        """Wait for daemon and wallet RPCs to be ready."""
        _log('--- Step 2: Waiting for node RPC ---')
        self._wait_for_daemon(timeout=60)
        _log('  Node RPC ready')
        _log('')

        _log('--- Step 3: Waiting for wallet RPCs ---')
        for name in ['gov', 'miner', 'test']:
            self._wait_for_wallet(name, timeout=30)
            _log(f'  {name} wallet RPC ready')
        _log('')

    def _wait_for_daemon(self, timeout=60):
        """Poll daemon RPC until responsive."""
        for i in range(timeout):
            try:
                self.client.height()
                return
            except Exception:
                if i == timeout - 1:
                    raise RuntimeError(f'Daemon RPC not ready after {timeout}s')
                time.sleep(1)

    def _wait_for_wallet(self, name, timeout=30):
        """Poll wallet RPC until responsive."""
        w = self.client._get_wallet(name)
        for i in range(timeout):
            try:
                w.get_version()
                return
            except Exception:
                if i == timeout - 1:
                    raise RuntimeError(f'{name} wallet RPC not ready after {timeout}s')
                time.sleep(1)

    def _restore_gov_wallet(self):
        _log('--- Step 4: Restoring governance wallet ---')
        try:
            self.client.open_wallet('gov', password='')
            _log('  Gov wallet: opened existing')
        except Exception:
            self.client.restore_wallet('gov', address=GOV_ADDRESS,
                                       spendkey=GOV_SPEND_KEY,
                                       viewkey=GOV_VIEW_KEY,
                                       password='', restore_height=0)
            _log('  Gov wallet: restored from keys')
        _log('')

    def _create_wallets(self):
        _log('--- Step 5: Creating base devnet wallets (miner, test) ---')
        for name in ['miner', 'test']:
            self.client.create_wallet(name)
            addr = self.client.get_address(name)
            _log(f'  {name} address: {addr[:20]}...')
        _log('')

    def _start_mining(self):
        _log(f'--- Step 6: Starting mining ({self.mining_threads} threads) ---')
        self.client.mine_start(wallet='miner', threads=self.mining_threads)
        _log('  Mining started')
        _log('')

    def _wait_governance_unlock(self):
        """Wait for height >= 70 so governance funds unlock (coinbase maturity=60)."""
        _log('--- Step 7: Waiting for block height >= 70 (governance unlock) ---')
        self.client.wait_for_height(70)
        _log('')

    def _run_setup_state(self):
        _log('=========================================')
        _log(f'  State Setup - Minting Sequence (mode: {self.setup_mode})')
        _log('=========================================')
        _log('')
        _log('Ring size is 2 for DEVNET. Sequential minting with waits.')
        _log('')

        self.client.refresh('gov')

        ss = SetupState(self.client, mode=self.setup_mode,
                        target_rr=self.target_rr,
                        zsd_mint_limit=self.zsd_limit)
        ss.run()

    def _stop_mining(self):
        _log('')
        _log('--- Stopping mining ---')
        self.client.mine_stop()
        _log('  Mining stopped')

    def _save_checkpoint(self):
        if not self.checkpoint_file:
            return
        _log('')
        _log('--- Saving checkpoint ---')
        height = self.client.height()
        checkpoint_dir = os.path.dirname(self.checkpoint_file)
        if checkpoint_dir:
            os.makedirs(checkpoint_dir, exist_ok=True)
        with open(self.checkpoint_file, 'w') as f:
            f.write(str(height))
        # Also save as init-height and mode
        init_height_file = os.path.join(checkpoint_dir, 'init-height') if checkpoint_dir else 'init-height'
        mode_file = os.path.join(checkpoint_dir, 'mode') if checkpoint_dir else 'mode'
        with open(init_height_file, 'w') as f:
            f.write(str(height))
        with open(mode_file, 'w') as f:
            f.write(self.setup_mode)
        _log(f'  Checkpoint saved at height: {height} (mode: {self.setup_mode})')


class DevnetSnapshot:
    """Save/restore LMDB snapshots for fast devnet state management."""

    def __init__(self, client, snapshot_dir=None):
        self.client = client
        self.snapshot_dir = snapshot_dir or os.path.expanduser('~/.zephyr-devnet/snapshots')

    def save(self, name='default'):
        """Save current LMDB state as a named snapshot.

        Note: Caller must stop daemons before calling this for consistency.
        This just saves the checkpoint metadata. Actual LMDB copying is done
        by the shell wrapper that has access to the filesystem.
        """
        _log(f'--- Saving snapshot: {name} ---')
        os.makedirs(self.snapshot_dir, exist_ok=True)
        height = self.client.height()
        meta_file = os.path.join(self.snapshot_dir, f'{name}.meta')
        with open(meta_file, 'w') as f:
            json.dump({'name': name, 'height': height,
                       'timestamp': int(time.time())}, f)
        _log(f'  Snapshot metadata saved: {name} at height {height}')
        return height

    def reset(self, name='default'):
        """Restore a named snapshot.

        Note: Actual LMDB restore (file copy) is done by the shell wrapper.
        This reads the snapshot metadata and reports what to expect.
        """
        meta_file = os.path.join(self.snapshot_dir, f'{name}.meta')
        if not os.path.isfile(meta_file):
            raise FileNotFoundError(f'No snapshot named {name!r} at {meta_file}')
        with open(meta_file) as f:
            meta = json.load(f)
        _log(f'  Restoring snapshot: {name} (height {meta["height"]})')
        return meta


def run_devnet_command(client, args):
    """Dispatch devnet subcommands."""
    if args.devnet_cmd == 'init':
        init = DevnetInit(
            client,
            oracle_price=args.oracle_price,
            mining_threads=args.mining_threads,
            setup_mode=args.mode,
            target_rr=args.target_rr,
            zsd_limit=args.zsd_limit,
            checkpoint_file=args.checkpoint_file,
        )
        init.run()

    elif args.devnet_cmd == 'snapshot':
        snap = DevnetSnapshot(client, snapshot_dir=args.snapshot_dir)
        snap.save(args.name)

    elif args.devnet_cmd == 'reset':
        snap = DevnetSnapshot(client, snapshot_dir=args.snapshot_dir)
        meta = snap.reset(args.name)
        _log(f'  Target height: {meta["height"]}')

    else:
        print('Usage: devnet {init|snapshot|reset} ...')
