// Where persisted state lives. The original hard-coded Windows' %LOCALAPPDATA%;
// this resolves the correct per-user location on every platform, and honours an
// override (used by tests and portable installs).

import os from 'node:os';
import path from 'node:path';

const APP_DIR_NAME = 'WizLightController';

/**
 * Absolute path to the app's data directory for the current platform.
 * Override with `WIZ_DATA_DIR` (or pass one in) for tests / portable use.
 */
export function appDataDir(override = process.env.WIZ_DATA_DIR) {
  if (override) return override;
  const home = os.homedir();
  switch (process.platform) {
    case 'darwin':
      return path.join(home, 'Library', 'Application Support', APP_DIR_NAME);
    case 'win32':
      return path.join(process.env.APPDATA || process.env.LOCALAPPDATA || home, APP_DIR_NAME);
    default:
      return path.join(
        process.env.XDG_CONFIG_HOME || path.join(home, '.config'),
        'wiz-light-controller',
      );
  }
}
