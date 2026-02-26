"""Configuration loading with env var overrides for Docker environments."""

import json
import os

DEFAULTS = {
    'daemon': {'host': '127.0.0.1', 'port': 47767},
    'daemon2': {'host': '127.0.0.1', 'port': 47867},
    'oracle': {'host': '127.0.0.1', 'port': 5555},
    'wallets': {
        'gov':   {'port': 48769, 'description': 'Governance wallet'},
        'miner': {'port': 48767, 'description': 'Miner wallet'},
        'test':  {'port': 48768, 'description': 'Test wallet'},
        'bridge': {'port': 48770, 'description': 'Bridge wallet'},
        'engine': {'port': 48771, 'description': 'Engine wallet'},
        'cex':   {'port': 48772, 'description': 'CEX (fake exchange) wallet'},
    },
}

DEFAULT_CONFIG_PATH = os.path.join(os.path.dirname(__file__), '..', 'configs', 'devnet.json')


def _apply_env_overrides(cfg):
    """Apply environment variable overrides on top of loaded config.

    Supported env vars:
        ZEPHYR_DAEMON_HOST / ZEPHYR_DAEMON_PORT
        ZEPHYR_ORACLE_HOST / ZEPHYR_ORACLE_PORT
        ZEPHYR_WALLET_{NAME}_HOST / ZEPHYR_WALLET_{NAME}_PORT
            e.g. ZEPHYR_WALLET_GOV_HOST=wallet-gov
    """
    # Daemon overrides
    if v := os.environ.get('ZEPHYR_DAEMON_HOST'):
        cfg.setdefault('daemon', {})['host'] = v
    if v := os.environ.get('ZEPHYR_DAEMON_PORT'):
        cfg.setdefault('daemon', {})['port'] = int(v)

    # Daemon2 overrides
    if v := os.environ.get('ZEPHYR_DAEMON2_HOST'):
        cfg.setdefault('daemon2', {})['host'] = v
    if v := os.environ.get('ZEPHYR_DAEMON2_PORT'):
        cfg.setdefault('daemon2', {})['port'] = int(v)

    # Oracle overrides
    if v := os.environ.get('ZEPHYR_ORACLE_HOST'):
        cfg.setdefault('oracle', {})['host'] = v
    if v := os.environ.get('ZEPHYR_ORACLE_PORT'):
        cfg.setdefault('oracle', {})['port'] = int(v)

    # Per-wallet overrides
    wallets = cfg.get('wallets', {})
    for name, wcfg in wallets.items():
        env_name = name.upper()
        if v := os.environ.get(f'ZEPHYR_WALLET_{env_name}_HOST'):
            wcfg['host'] = v
        if v := os.environ.get(f'ZEPHYR_WALLET_{env_name}_PORT'):
            wcfg['port'] = int(v)

    return cfg


def load_config(config=None, config_path=None):
    """Load config from dict, JSON file, or fall back to defaults.

    Priority: explicit dict > config_path > bundled devnet.json > hardcoded defaults.
    Environment variables are always applied on top.
    """
    if config is not None:
        return _apply_env_overrides(config)

    path = config_path or DEFAULT_CONFIG_PATH
    path = os.path.expanduser(path)

    if os.path.isfile(path):
        with open(path) as f:
            cfg = json.load(f)
    else:
        cfg = json.loads(json.dumps(DEFAULTS))  # deep copy

    return _apply_env_overrides(cfg)
