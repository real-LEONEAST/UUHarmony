import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
export interface RetainedTerminal {id:number;createdAt:number;name:string;agent:string;}
// Only reconnection metadata. Never stores terminal output, commands or credentials.
export class TerminalRetainedStore {
 private store:preferences.Preferences|undefined=undefined;
 private key:string='';
 private tail:Promise<boolean>=Promise.resolve(true);
 initialize(context:common.Context,account:string,device:string):void {this.store=preferences.getPreferencesSync(context,{name:'terminal_retained_v2'});this.key=account+'|'+device;}
 load():RetainedTerminal[]{try{const value=this.store?.getSync(this.key,'[]');if(typeof value!=='string'){return [];}const rows=JSON.parse(value) as RetainedTerminal[];return rows.filter((r:RetainedTerminal)=>Number.isInteger(r.id)&&r.createdAt>0&&typeof r.name==='string'&&(r.agent==='ordinary'||r.agent==='codex')).slice(0,64);}catch(_){return [];}}
 save(rows:RetainedTerminal[]):Promise<boolean>{const payload=JSON.stringify(rows);const next=this.tail.then(async()=>{if(!this.store||rows.length>64){return false;}try{this.store.putSync(this.key,payload);await this.store.flush();return true;}catch(_){return false;}});this.tail=next;return next;}
}
