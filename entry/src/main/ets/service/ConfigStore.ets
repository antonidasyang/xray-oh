import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { logger } from '../util/Logger';

const log = logger('ConfigStore');

// Keeps the last Xray config in the UI process. The VPN extension never reads
// it: preferences are not shared across processes, the config goes in the Want.
class ConfigStoreImpl {
  private prefs?: preferences.Preferences;

  async init(context: common.UIAbilityContext): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(context, 'xray');
    } catch (e) {
      log.error('getPreferences failed', e as Object);
    }
  }

  load(): string {
    if (!this.prefs) return '';
    try {
      return this.prefs.getSync('config', '') as string;
    } catch (e) {
      log.error('load failed', e as Object);
      return '';
    }
  }

  async save(config: string): Promise<void> {
    if (!this.prefs) return;
    try {
      this.prefs.putSync('config', config);
      await this.prefs.flush();
    } catch (e) {
      log.error('save failed', e as Object);
    }
  }
}

export const ConfigStore = new ConfigStoreImpl();
