import json
import os

DEFAULTS = {
    'daemon': {'host': '127.0.0.1', 'port': 47767},
    'oracle': {'host': '127.0.0.1', 'port': 5555},
    'wallets': {
        'gov':   {'port': 48769, 'description': 'Governance wallet'},
        'miner': {'port': 48767, 'description': 'Miner wallet'},
        'test':  {'port': 48768, 'description': 'Test wallet'},
    },
}

DEFAULT_CONFIG_PATH = os.path.join(os.path.dirname(__file__), '..', 'configs', 'devnet.json')


def load_config(config=None, config_path=None):
    """Load config from dict, JSON file, or fall back to defaults.

    Priority: explicit dict > config_path > bundled devnet.json > hardcoded defaults.
    """
    if config is not None:
        return config

    path = config_path or DEFAULT_CONFIG_PATH
    path = os.path.expanduser(path)

    if os.path.isfile(path):
        with open(path) as f:
            return json.load(f)

    return DEFAULTS.copy()
