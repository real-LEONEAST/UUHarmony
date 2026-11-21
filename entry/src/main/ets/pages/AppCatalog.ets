import { preferences } from '@kit.ArkData';
import { session } from './SessionClient';
import { AdvancedCommand } from './AdvancedClient';

export interface PinnedApp {id:string; name:string;}
export const APP_STORE='device_quick_launch_v1';
export function readPinnedApps(store:preferences.Preferences,key:string):PinnedApp[] {
  if(!key||key==='assistance'){return [];}
  try {
    const raw=store.getSync(key,'[]');
    if(typeof raw!=='string'){return [];}
    return (JSON.parse(raw) as PinnedApp[]).filter((app:PinnedApp)=>/^[a-f0-9]{64}$/.test(app.id)&&typeof app.name==='string');
  }catch(_){return [];}
}
type Changed=()=>void;
const observers:Set<Changed>=new Set();
export function onAppsChanged(callback:Changed):()=>void{observers.add(callback);return ()=>{observers.delete(callback);};}
export async function saveApps(store:preferences.Preferences,key:string,rows:PinnedApp[]):Promise<void>{
  store.putSync(key,JSON.stringify(rows));await store.flush();observers.forEach((changed:Changed)=>changed());
}

interface CatalogEvent {action:string;id?:string;list?:boolean;confirmed?:boolean;}
export interface CatalogReply {phase?:string;error?:string;sent?:boolean;pending?:boolean;apps?:PinnedApp[];icon?:string;iconId?:string;}
async function request(event:CatalogEvent):Promise<CatalogReply>{
  const command:AdvancedCommand={op:'peer_catalog',event:event};
  return JSON.parse(await session.catalogCommand(command)) as CatalogReply;
}
export function delay(ms:number):Promise<void>{return new Promise<void>((resolve)=>{setTimeout(resolve,ms);});}
export async function scanApps(valid:()=>boolean):Promise<PinnedApp[]>{
  const end=Date.now()+15000;
  let sent=false;
  const generation=session.generation;const device=session.selected;
  const current=():boolean=>valid()&&session.generation===generation&&session.selected===device;
  while(current()&&Date.now()<end){
    if(!sent){const start=await request({action:'scan'});if(!current()){break;}sent=start.sent===true;if(!sent&&start.error!=='catalog_channel_opening'){throw new Error('应用列表请求失败');}}
    else{
      const status=await request({action:'status'});if(!current()){break;}
      if(status.phase==='ready'){const list=await request({action:'status',list:true});if(current()){return list.apps||[];}break;}
      if(status.phase==='failed'||status.error){throw new Error('电脑未提供应用列表');}
    }
    await delay(160);
  }
  throw new Error('电脑尚未返回应用列表');
}
export async function readAppIcon(id:string,valid:()=>boolean):Promise<string>{
  const generation=session.generation;const device=session.selected;
  const current=():boolean=>valid()&&session.generation===generation&&session.selected===device;
  if(!current()||!(await request({action:'icon',id:id})).sent||!current()){return '';}
  const end=Date.now()+1500;
  while(current()&&Date.now()<end){const r=await request({action:'status'});if(!current()){return '';}if(!r.pending){return r.iconId===id?r.icon||'':'';}await delay(120);}
  return '';
}
export async function launchSelectedApp(id:string,valid:()=>boolean):Promise<string>{
  if(!/^[a-f0-9]{64}$/.test(id)||!valid()){return '当前无法启动应用';}
  const generation=session.generation;const device=session.selected;
  const current=():boolean=>valid()&&session.generation===generation&&session.selected===device;
  try{
    const apps=await scanApps(current);
    if(!current()){return '会话已结束';}
    if(!apps.some((app:PinnedApp)=>app.id===id)){return '电脑已移除该应用';}
    return (await request({action:'launch',id:id,confirmed:true})).sent?'已发送启动请求':'启动请求发送失败';
  }catch(_){return '无法取得这台电脑的应用列表';}
}
