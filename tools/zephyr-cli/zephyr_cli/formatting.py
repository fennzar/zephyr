"""Table formatting helpers for CLI output."""

COIN = 1_000_000_000_000  # 10^12 atomic units
ASSETS = ['ZPH', 'ZRS', 'ZSD', 'ZYS']


def atomic_to_display(atomic):
    """Convert atomic units (int) to human-readable string with commas."""
    if atomic is None or atomic == 0:
        return '-'
    value = atomic / COIN
    if value == int(value):
        return f'{int(value):,}.00'
    return f'{value:,.2f}'


def format_amount(amount_float):
    """Format a float amount for display."""
    if amount_float == int(amount_float):
        return f'{int(amount_float):,}.00'
    return f'{amount_float:,.4f}'


def format_balances_table(wallet_balances):
    """Format multi-wallet, multi-asset balances as a table.

    wallet_balances: dict of {wallet_name: {asset: atomic_balance, ...}, ...}
    """
    header = ['Wallet'] + ASSETS
    rows = []
    for name in sorted(wallet_balances):
        bals = wallet_balances[name]
        row = [name]
        for asset in ASSETS:
            row.append(atomic_to_display(bals.get(asset, 0)))
        rows.append(row)

    # Calculate column widths
    widths = [max(len(header[i]), *(len(r[i]) for r in rows)) for i in range(len(header))]

    lines = []
    hdr = '  '.join(h.ljust(widths[i]) for i, h in enumerate(header))
    lines.append(hdr)
    lines.append('  '.join('-' * widths[i] for i in range(len(header))))
    for row in rows:
        lines.append('  '.join(row[i].rjust(widths[i]) if i > 0 else row[i].ljust(widths[i])
                                for i in range(len(row))))
    return '\n'.join(lines)


def format_daemon_info(info):
    """Format daemon get_info response as readable key-value pairs."""
    # Show most useful fields in a sensible order
    priority_keys = [
        'height', 'target_height', 'difficulty', 'synchronized',
        'tx_count', 'tx_pool_size', 'white_peerlist_size', 'grey_peerlist_size',
        'incoming_connections_count', 'outgoing_connections_count',
        'version', 'nettype', 'top_block_hash',
    ]
    lines = []
    shown = set()
    for key in priority_keys:
        if key in info:
            lines.append(f'  {key}: {info[key]}')
            shown.add(key)
    for key in sorted(info.keys()):
        if key not in shown and key != 'status':
            lines.append(f'  {key}: {info[key]}')
    return '\n'.join(lines)


def format_reserve_info(info):
    """Format reserve info response as readable text."""
    lines = []
    for key in sorted(info.keys()):
        val = info[key]
        if isinstance(val, int) and val > 1_000_000_000:
            lines.append(f'  {key}: {atomic_to_display(val)} ({val})')
        else:
            lines.append(f'  {key}: {val}')
    return '\n'.join(lines)
