import { virtualLibraryLifecycle } from '../pages/VirtualLibraryLifecycle';
import { virtualSelection } from '../pages/VirtualPlanSelection';
import { AuthView } from '../pages/AuthClient';
import { UIAbility, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appAppearance } from '../pages/AppAppearance';
import { client } from '../pages/AuthClient';
import { detached } from '../pages/DetachedCoordinator';
import { session } from '../pages/SessionClient';
import { windowPolicy } from '../pages/WindowPolicy';
import { pcHost } from '../pc/PcHostService';
import { pcFileWindows } from '../pc/PcFileWindows';
import type { TrayController } from '../pc/PcTray';
import { localDeviceProfile } from '../pages/LocalDeviceProfile';

export default class EntryAbility extends UIAbility {
  private selectionMonitor:()=>void=()=>{};
  private tray:TrayController|undefined=undefined;
  private mainWindow:window.Window|undefined=undefined;
  private closeStage:window.WindowStage|undefined=undefined;
  private hidingWindow:window.Window|undefined=undefined;
  private destroyed:boolean=false;
  private closeWindow=():boolean=>{
    if(this.tray?.isExiting()){return false;}
    const current=this.mainWindow;
    if(!current||this.hidingWindow===current){return true;}
    const primaryOnly=session.busy&&session.multiMode&&detached.hasPane();
    if(!primaryOnly&&windowPolicy.requestRemoteClose()){return true;}
    this.hidingWindow=current;
    setTimeout(()=>{this.hideMainWindow(current,primaryOnly)
      .catch(()=>{hilog.warn(0x0303,'UUTitle','main_window_hide_failed');});},0);
    return true;
  };
  private closeWindowAsync=async ():Promise<boolean>=>this.closeWindow();
  private async hideMainWindow(current:window.Window,primaryOnly:boolean):Promise<void>{
    try{
      if(current!==this.mainWindow||this.destroyed){return;}
      if(primaryOnly){await session.closeMultiPrimary();}
      else if(session.busy){await session.cancel('user_disconnect');}
      if(current!==this.mainWindow||this.destroyed){return;}
      try{if(await this.tray?.hide()){return;}}catch(_){}
      if(current===this.mainWindow&&!this.destroyed){await current.minimize();}
    }finally{if(this.hidingWindow===current){this.hidingWindow=undefined;}}
  }
  onCreate():void {
    client.setRegistrationStore(this.context);
    this.selectionMonitor=client.monitor((view:AuthView)=>virtualSelection.setScope(view.loggedIn?(view.wallpaperAccountKey||'unavailable'):'offline'));
    client.setDeviceProfileProvider(()=>localDeviceProfile(this.context));
    appAppearance.initialize(this.context);
    if(pcHost.supported){client.setBeforeLoad(async()=>{await pcHost.initialize(this.context);});}
  }
  onConfigurationUpdate(_configuration:Configuration):void {windowPolicy.refreshSystemBars();}
  onWindowStageCreate(stage:window.WindowStage):void {
    windowPolicy.attach(stage,this.context);
    if(pcHost.supported){
      pcFileWindows.attach(stage);
      this.mainWindow=stage.getMainWindowSync();
      try{this.mainWindow.on('windowWillClose',this.closeWindowAsync);}
      catch(_){try{stage.on('windowStageClose',this.closeWindow);this.closeStage=stage;}catch(_){hilog.warn(0x0303,'UUTitle','main_close_listener_unavailable');}}
      this.installTray();
    }
    stage.on('windowStageEvent',(event:window.WindowStageEventType)=>{if(event===window.WindowStageEventType.INACTIVE){session.setWindowActive(false);}else if(event===window.WindowStageEventType.ACTIVE){session.setWindowActive(true);}});
    stage.loadContent('pages/Index');
  }
  onForeground():void {windowPolicy.setScreenForeground(true);windowPolicy.refreshSystemBars();session.setForeground(true,!pcHost.supported);if(pcHost.supported){try{session.setWindowActive(this.mainWindow?.isFocused()===true);}catch(_){session.setWindowActive(false);}}client.resume();}
  onBackground():void {virtualLibraryLifecycle.suspend();windowPolicy.setScreenForeground(false);if(!detached.hasPane()){session.setForeground(false);}else{session.setWindowActive(false);}client.suspend();if(session.busy&&!pcHost.supported){session.cancel('application_background');}}
  private async installTray():Promise<void> {
    try{const module=await import('../pc/PcTray');if(this.destroyed){return;}
      this.tray=new module.TrayController(this.context,()=>pcHost.stop(),async()=>{if(session.busy){await session.cancel('tray_exit');}});
      await this.tray.install();
    }catch(_){hilog.warn(0x0303,'UUHarmonyTray','tray_unavailable');}
  }
  onWindowStageDestroy():void {
    pcFileWindows.detach();
    if(this.closeStage){try{this.closeStage.off('windowStageClose',this.closeWindow);}catch(_){}}
    else{try{this.mainWindow?.off('windowWillClose',this.closeWindowAsync);}catch(_){}}
    this.closeStage=undefined;this.mainWindow=undefined;this.hidingWindow=undefined;
    windowPolicy.setScreenForeground(false);if(session.busy){session.cancel('window_stage_destroyed');}windowPolicy.detach();
  }
  onDestroy():void {this.selectionMonitor();virtualSelection.clear();windowPolicy.setScreenForeground(false);this.destroyed=true;client.suspend();if(session.busy){session.cancel('application_destroyed');}pcHost.dispose();this.tray?.dispose();windowPolicy.detach();}
}
