import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { VpnController } from '../service/VpnController';
import { ConfigStore } from '../service/ConfigStore';
import { logger } from '../util/Logger';

const log = logger('EntryAbility');

export default class EntryAbility extends UIAbility {
  async onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): Promise<void> {
    await ConfigStore.init(this.context);
    await VpnController.init(this.context);
  }

  async onDestroy(): Promise<void> {
    // The tunnel keeps running in its own process; only the UI goes away.
    await VpnController.dispose();
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index', (err) => {
      if (err && err.code) log.error('loadContent failed', err);
    });
  }
}
