import { common, Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { WindowPolicy, windowPolicy } from './WindowPolicy';
import { session } from './SessionClient';
export interface DetachedLease {lease:string;screenId:number;surface:string;focused:boolean;ready:boolean;slot:number;transferred:boolean;closing:boolean;pending:boolean;timer:number;policy?:WindowPolicy;terminate?:()=>void;}
class DetachedCoordinator {
 private entries:Map<string,DetachedLease>=new Map();private listeners:Map<number,()=>void>=new Map();private listenerId:number=0;
 observe(fn:()=>void):()=>void{const id=++this.listenerId;this.listeners.set(id,fn);return ()=>{this.listeners.delete(id);};}
 private changed():void{this.listeners.forEach((fn:()=>void)=>{try{fn();}catch(_){}});}
 lookup(lease:string):DetachedLease|undefined{return this.entries.get(lease);}
 current():DetachedLease|undefined{let first:DetachedLease|undefined=undefined;this.entries.forEach((e:DetachedLease)=>{if(!first){first=e;}});return first;}
 hasPane():boolean{return this.entries.size>0;}
 async showScreen(id:number):Promise<boolean>{const panes:DetachedLease[]=[];this.entries.forEach((e:DetachedLease)=>panes.push(e));const pane=panes.find((e:DetachedLease)=>e.screenId===id);if(!pane||pane.closing){return false;}let sourceId=windowPolicy.ownWindowFocused()?windowPolicy.ownWindowId():0;panes.forEach((e:DetachedLease)=>{if(e.policy?.ownWindowFocused()){sourceId=e.policy.ownWindowId();}});return pane.policy?await pane.policy.focusOwnWindow(sourceId):true;}
 hasScreen(id:number):boolean{let found=false;this.entries.forEach((e:DetachedLease)=>{if(e.screenId===id){found=true;}});return found;}
 setPolicy(lease:string,policy:WindowPolicy):void{const e=this.lookup(lease);if(e){e.policy=policy;}}
 getPolicy(lease:string):WindowPolicy|undefined{return this.lookup(lease)?.policy;}
 clearPolicy(policy:WindowPolicy):void{this.entries.forEach((e:DetachedLease)=>{if(e.policy===policy){e.policy=undefined;}});}
 private abandon(e:DetachedLease):void{if(this.lookup(e.lease)!==e){return;}clearTimeout(e.timer);this.entries.delete(e.lease);session.detachedReleased(e.screenId);this.changed();e.terminate?.();}
 async open(context:common.UIAbilityContext,screenId:number):Promise<boolean>{
  const multi=session.multi;if(!multi||!multi.snapshot().screens.some((r)=>r.id===screenId)){return false;}if(this.hasScreen(screenId)){return this.showScreen(screenId);}
  const transfer=screenId===session.primaryScreenId;let slot=transfer?session.primarySlotId:-1;
  if(!transfer){const used:number[]=[];this.entries.forEach((e:DetachedLease)=>used.push(e.slot));if(session.primaryScreenId>=0){used.push(session.primarySlotId);}slot=[0,1,2].find((s:number)=>!used.includes(s))??-1;}
  if(slot<0){return false;}const lease=util.generateRandomUUID();const e:DetachedLease={lease:lease,screenId:screenId,surface:'',focused:false,ready:false,slot:slot,transferred:transfer,closing:false,pending:false,timer:-1};
  this.entries.set(lease,e);session.registerDetachedScreen(screenId);this.changed();e.timer=setTimeout(()=>{if(this.lookup(lease)===e&&!e.surface){this.abandon(e);}},10000);
  const want:Want={bundleName:context.abilityInfo.bundleName,abilityName:'DetachedViewAbility',parameters:{lease:lease}};
  try{await context.startAbility(want);return this.lookup(lease)===e;}catch(_){this.abandon(e);return false;}
 }
 async attach(lease:string,surface:string,terminate:()=>void):Promise<boolean>{
  const e=this.lookup(lease),multi=session.multi;if(!e||!multi||e.surface){return false;}clearTimeout(e.timer);e.timer=-1;e.surface=surface;e.terminate=terminate;
  try{if(e.transferred){if(!await session.transferPrimary(surface)){throw new Error('transfer_failed');}}else{await multi.open(e.screenId,e.slot,surface);}if(this.lookup(lease)!==e||e.closing){return false;}e.ready=true;this.changed();return true;}catch(_){if(this.lookup(lease)===e){this.abandon(e);}return false;}
 }
 focus(lease:string,focused:boolean):void{const e=this.lookup(lease);if(!e){return;}e.focused=focused;if(!focused){session.multi?.revoke(lease).catch(()=>{});}else{session.setForeground(true,false);this.claim(lease);}this.changed();}
 claim(lease:string):void{const e=this.lookup(lease),multi=session.multi;if(!e||!multi||!e.focused||!e.ready||e.closing||e.pending||multi.isOwner(e.screenId,lease)){return;}e.pending=true;multi.claim(e.screenId,lease,()=>this.lookup(lease)===e&&e.focused&&e.ready&&!e.closing&&session.multi===multi).then(()=>{e.pending=false;this.changed();},()=>{e.pending=false;this.changed();});}
 async close(lease:string,merge:boolean=false):Promise<void>{
  const e=this.lookup(lease),multi=session.multi;if(!e||e.closing){return;}if(merge&&(!session.primarySurfaceAvailable||!await windowPolicy.showMainWindow())){throw new Error('主窗口不可用');}e.closing=true;e.focused=false;
  try{await multi?.revoke(lease);if(multi&&e.surface){await multi.close(e.screenId,e.slot);}if(this.lookup(lease)!==e||session.multi!==multi){return;}session.detachedReleased(e.screenId);
   if(merge&&session.busy&&!await session.switchMultiPrimary(e.screenId)){session.registerDetachedScreen(e.screenId);if(multi&&e.surface){await multi.open(e.screenId,e.slot,e.surface);}throw new Error('merge_failed');}
   this.abandon(e);if(session.busy&&session.primaryScreenId<0&&!this.hasPane()){await session.cancel('user_disconnect');}
  }catch(error){e.closing=false;this.changed();throw new Error((error as Error).message||'screen_close_failed');}
 }
 disconnected():void{const values:DetachedLease[]=[];this.entries.forEach((e:DetachedLease)=>values.push(e));this.entries.clear();values.forEach((e:DetachedLease)=>{clearTimeout(e.timer);session.detachedReleased(e.screenId);e.terminate?.();});this.changed();}
}
export const detached=new DetachedCoordinator();
