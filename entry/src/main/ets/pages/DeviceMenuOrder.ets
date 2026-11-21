import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { MORE_ACTIONS, normalizeMoreOrder } from './DeviceDetailsModel';
export class DeviceMenuOrder {
  private context:common.Context;
  constructor(context:common.Context){this.context=context;}
  private key(account:string,device:string):string{if(!/^[a-f0-9]{64}$/.test(account)||!/^[a-f0-9]{64}$/.test(device)){throw new Error('menu_order_scope_required');}return device;}
  load(account:string,device:string):string[]{
    try{const key=this.key(account,device);const store=preferences.getPreferencesSync(this.context,{name:'device_menu_order_v23_'+account});const raw=store.getSync(key,'');if(typeof raw!=='string'||raw.length>256){return MORE_ACTIONS.slice();}return normalizeMoreOrder(JSON.parse(raw) as string[]);}
    catch(_){return MORE_ACTIONS.slice();}
  }
  async save(account:string,device:string,order:string[]):Promise<boolean>{
    try{const key=this.key(account,device);const store=preferences.getPreferencesSync(this.context,{name:'device_menu_order_v23_'+account});store.putSync(key,JSON.stringify(normalizeMoreOrder(order)));await store.flush();return true;}
    catch(_){return false;}
  }
}
