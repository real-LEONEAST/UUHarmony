import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// Application appearance only. Never writes a device-wide system setting.
export class AppAppearance {
  private context:common.Context|undefined=undefined;
  private store:preferences.Preferences|undefined=undefined;
  private selected:number=0;
  private tail:Promise<boolean>=Promise.resolve(true);
  initialize(context:common.Context):void {
    this.context=context;
    try{this.store=preferences.getPreferencesSync(context,{name:'application_appearance_v1'});const saved=this.store.getSync('mode',0);this.selected=saved===1||saved===2?saved:0;}catch(_){this.selected=0;}
    try{this.apply(this.selected);}catch(_){}
  }
  value():number{return this.selected;}
  private apply(value:number):void {
    if(!this.context){throw new Error('appearance_context_unavailable');}
    const modes=[ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET,ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT,ConfigurationConstant.ColorMode.COLOR_MODE_DARK];
    this.context.getApplicationContext().setColorMode(modes[value]);
  }
  choose(value:number):Promise<boolean>{
    if(!Number.isInteger(value)||value<0||value>2){return Promise.resolve(false);}
    const next=this.tail.then(async()=>{const old=this.selected;if(!this.store){return false;}try{this.apply(value);this.store.putSync('mode',value);await this.store.flush();this.selected=value;return true;}catch(_){try{this.apply(old);this.store.putSync('mode',old);await this.store.flush();}catch(_){}return false;}});
    this.tail=next;return next;
  }
}
export const appAppearance=new AppAppearance();
