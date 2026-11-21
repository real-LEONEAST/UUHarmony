// SPDX-License-Identifier: GPL-3.0-only
import { common } from '@kit.AbilityKit';
import { CodexCache } from './CodexCache';
import { CodexScope } from './CodexHistoryModel';
import { NotebookMeta,NotebookIndex,NotebookRecord,NotebookScreen,notebookScope,notebookIndex,notebookMeta,notebookScreen,notebookRedact } from './TerminalNotebookModel';
export class TerminalNotebookStore {
 private cache:CodexCache=new CodexCache();
 setContext(context:common.UIAbilityContext):void{this.cache.setContext(context,'terminal-notebook-v1');}
 epoch():number{return this.cache.epoch();}
 private scope(meta:NotebookMeta):CodexScope {notebookScope(meta.account,meta.device);if(!notebookMeta(meta,meta.account,meta.device)){throw new Error('notebook_meta');}return {account:meta.account,device:meta.device,profile:'0'.repeat(64),workspace:'0'.repeat(64),threadId:meta.id};}
 async index(account:string,device:string):Promise<NotebookMeta[]> {
  notebookScope(account,device);const raw=await this.cache.read(this.cache.indexKey(account,device));try{return raw?notebookIndex(JSON.parse(raw) as NotebookIndex,account,device):[];}catch(_){return [];}
 }
 async read(meta:NotebookMeta):Promise<NotebookRecord|undefined>{
  const raw=await this.cache.read(await this.cache.pageKey(this.scope(meta),'screen'));try{if(raw){const r=JSON.parse(raw) as NotebookRecord;if(r.version===1&&r.meta.id===meta.id&&notebookMeta(r.meta,meta.account,meta.device)&&notebookScreen(r.screen)){return r;}}}catch(_){}return undefined;
 }
 async save(meta:NotebookMeta,screen:NotebookScreen,expected:number):Promise<boolean>{
  if(!notebookScreen(screen)){return false;}const key=await this.cache.pageKey(this.scope(meta),'screen');
  const safe:NotebookScreen={snapshot:notebookRedact(screen.snapshot),plain:notebookRedact(screen.plain),cols:screen.cols,rows:screen.rows};
  const saved=await this.cache.write(key,JSON.stringify({version:1,meta:meta,screen:safe} as NotebookRecord),expected);if(!saved){return false;}
  const records=(await this.index(meta.account,meta.device)).filter((m:NotebookMeta)=>m.id!==meta.id);if(records.length>=64){return false;}records.push(meta);
  return this.cache.write(this.cache.indexKey(meta.account,meta.device),JSON.stringify({version:1,account:meta.account,device:meta.device,records:records} as NotebookIndex),expected);
 }
 async clearRecord(meta:NotebookMeta):Promise<boolean>{
  const scope=this.scope(meta);if(!await this.cache.clearThread(scope)){return false;}const expected=this.epoch();const records=(await this.index(meta.account,meta.device)).filter((m:NotebookMeta)=>m.id!==meta.id);
  return this.cache.write(this.cache.indexKey(meta.account,meta.device),JSON.stringify({version:1,account:meta.account,device:meta.device,records:records} as NotebookIndex),expected);
 }
 async clearComputer(account:string,device:string):Promise<boolean>{notebookScope(account,device);return this.cache.clearComputer(account,device);}
}
