import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppService } from '../service/AppService';

const LOG_TAG = 'DshMobile';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, LOG_TAG, 'EntryAbility onCreate');
    // The page container talks to the network and to ArkWeb, both of which need the ability context.
    AppService.get().attachContext(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, LOG_TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      // The app chrome is dark in every system theme, so the system bars follow it.
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#0B0E14',
        statusBarContentColor: '#F2F5FA',
        navigationBarColor: '#0B0E14',
        navigationBarContentColor: '#F2F5FA'
      }).catch((error: Error) => {
        hilog.warn(0x0000, LOG_TAG, 'system bar styling unavailable: %{public}s', error.message);
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, LOG_TAG, 'EntryAbility onWindowStageDestroy');
  }
}
