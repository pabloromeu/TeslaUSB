"""
Shared config.yaml update utility.

Provides atomic writes to config.yaml from any blueprint or service.
Uses temp file + os.replace() for crash safety.
"""

import os
import sys
import yaml

from config import CONFIG_YAML


def update_config_yaml(updates: dict) -> None:
    """Atomically update config.yaml with new values.

    Also updates the in-memory config dict and any derived module-level
    constants so that subsequent requests see the new values without a
    service restart.

    Args:
        updates: Dict of dotted-key paths to new values,
                 e.g. ``{'cloud_archive.max_upload_mbps': 10}``.
    """
    with open(CONFIG_YAML, 'r') as f:
        cfg = yaml.safe_load(f) or {}

    for key, value in updates.items():
        keys = key.split('.')
        d = cfg
        for k in keys[:-1]:
            d = d.setdefault(k, {})
        d[keys[-1]] = value

    tmp_path = CONFIG_YAML + '.tmp'
    with open(tmp_path, 'w') as f:
        yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, CONFIG_YAML)

    # Mirror changes into the live in-memory config dict so the running
    # process sees the new values immediately (no restart needed).
    config_mod = sys.modules.get('config')
    if config_mod is not None:
        for key, value in updates.items():
            keys = key.split('.')
            d = config_mod.config
            for k in keys[:-1]:
                d = d.setdefault(k, {})
            d[keys[-1]] = value

        # Refresh derived constants that depend on config values.
        # NOTE: add an entry here whenever a new module-level constant in
        # config.py is derived from a config key that can be live-updated.
        # Currently only USE_METRIC (web.units) is live-updated via the UI.
        config_mod.USE_METRIC = (
            config_mod.config.get('web', {}).get('units', 'imperial').lower() == 'metric'
        )
