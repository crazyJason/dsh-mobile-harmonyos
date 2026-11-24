import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AppService } from '../service/AppService';
import { Log } from '../common/Log';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Log.info('EntryAbility onCreate');
    // The UI is dark-only, so system-drawn surfaces (dialogs, toasts, text selection menus) must
    // follow it instead of the device theme; otherwise a light dialog pops over the dark app.
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (error) {
      Log.warn('dark color mode unavailable');
    }
    // The page container talks to the network and to ArkWeb, both of which need the ability context.
    AppService.get().attachContext(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Log.error(`loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      // The app chrome is dark in every system theme, so the system bars follow it.
      // The window background matters as well: on HarmonyOS 7 the bottom navigation-bar strip
      // paints the window background, so leaving it at the default white shows a bright band.
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowBackgroundColor('#0B0E14');
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#0B0E14',
        statusBarContentColor: '#F2F5FA',
        navigationBarColor: '#0B0E14',
        navigationBarContentColor: '#F2F5FA'
      }).catch((error: Error) => {
        Log.warn(`system bar styling unavailable: ${error.message}`);
      });
    });
  }

  onWindowStageDestroy(): void {
    Log.info('EntryAbility onWindowStageDestroy');
  }
}
