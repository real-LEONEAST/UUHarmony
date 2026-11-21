// SPDX-License-Identifier: GPL-3.0-only
export interface CodexThread {id:string;workspace:string;workspaceLabel:string;name:string;updatedAt:number;status:string;owned?:boolean;parentId?:string;}
export interface CodexImage {id:string;label:string;available:boolean;}
export interface CodexMessage {id:string;turnId:string;type:string;text:string;status:string;images:CodexImage[];truncated:boolean;order?:number;}
export interface CodexPage {threadId:string;workspace:string;data:CodexMessage[];nextCursor:string|null;checkedAt:number;partial?:boolean;base?:string;liveRevision?:number;}
export interface CodexQuestionOption {label:string;description:string;}
export interface CodexQuestion {id:string;header:string;question:string;options:CodexQuestionOption[];secret:boolean;}
export interface CodexInteraction {id:string;threadId:string;turnId:string;kind:string;detail:string;available:boolean;questions:CodexQuestion[];bridgeInstance:string;}
export interface CodexRuntimeReply {error?:string;threadId?:string;turnId?:string;workspace?:string;writable?:boolean;latestTurnId?:string;running?:boolean;bridgeInstance?:string;thread?:CodexThread;items?:CodexMessage[];pending?:CodexInteraction[];revision?:number;reset?:boolean;resync?:boolean;checkedAt?:number;accepted?:boolean;uncertain?:boolean;answered?:boolean;unconfirmed?:boolean;}
export interface CodexIndex {profile:string;threads:CodexThread[];nextCursor:string|null;checkedAt:number;}
export interface CodexScope {account:string;device:string;profile:string;workspace:string;threadId:string;}
export function codexScopeParts(s:CodexScope):string[] {
  if(![s.account,s.device,s.profile,s.workspace].every((x:string)=>/^[a-f0-9]{64}$/.test(x))||!s.threadId||s.threadId.length>160||/[\u0000-\u001f]/.test(s.threadId)){throw new Error('codex_scope_required');}
  return [s.account,s.device,s.profile,s.workspace,s.threadId];
}
export class CodexHistoryModel {
  messages:CodexMessage[]=[];nextCursor:string|null=null;state:string='empty';checkedAt:number=0;
  private run:number=0;private thread:string='';private workspace:string='';private cursors:Set<string>=new Set<string>();
  open(thread:string,workspace:string,cached?:CodexPage):number {
    this.run++;this.thread=thread;this.workspace=workspace;this.cursors.clear();this.messages=[];this.nextCursor=null;this.checkedAt=0;this.state='loading';
    if(cached&&Array.isArray(cached.data)&&cached.threadId===thread&&cached.workspace===workspace){this.messages=this.unique(cached.data.slice().reverse());this.checkedAt=cached.checkedAt;this.nextCursor=cached.nextCursor;this.state='cached';}
    return this.run;
  }
  recent(run:number,page:CodexPage):boolean {
    if(!this.matches(run,page)){return false;}
    // No durable event revision: replace the verified window and retire old cursors.
    this.messages=this.unique(page.data.slice().reverse());this.nextCursor=page.nextCursor;this.checkedAt=page.checkedAt;this.cursors.clear();this.state=this.messages.length?'ready':'empty';return true;
  }
  older(run:number,cursor:string,page:CodexPage):boolean {
    if(!this.matches(run,page)||cursor!==this.nextCursor||this.cursors.has(cursor)){return false;}
    if(page.nextCursor===cursor||page.nextCursor!==null&&this.cursors.has(page.nextCursor)){this.state='failed';return false;}
    this.cursors.add(cursor);this.messages=this.unique(page.data.slice().reverse().concat(this.messages));this.nextCursor=page.nextCursor;this.checkedAt=page.checkedAt;this.state='ready';return true;
  }
  fail(run:number):void {if(run===this.run){this.state=this.messages.length?'cached_error':'failed';}}
  live(run:number,thread:string,workspace:string,items:CodexMessage[]):boolean {
    if(run!==this.run||thread!==this.thread||workspace!==this.workspace){return false;}
    const next=this.messages.slice();
    for(const m of items){
      if(!m.id||!m.turnId||typeof m.text!=='string'||!Array.isArray(m.images)){throw new Error('codex_live_item_invalid');}
      const index=next.findIndex((old:CodexMessage)=>old.id===m.id&&old.turnId===m.turnId);
      if(index>=0){next[index]=m;continue;}
      const before=m.order===undefined?-1:next.findIndex((old:CodexMessage)=>old.turnId===m.turnId&&old.order!==undefined&&old.order!>m.order!);
      if(before>=0){next.splice(before,0,m);}else{next.push(m);}
    }
    this.messages=this.unique(next);this.state='live';return true;
  }
  offline():void {this.run++;this.state=this.messages.length?'offline_cache':'offline';}
  token():number{return this.run;}
  private matches(run:number,p:CodexPage):boolean{return run===this.run&&p.threadId===this.thread&&p.workspace===this.workspace;}
  private unique(items:CodexMessage[]):CodexMessage[]{
    const seen:Set<string>=new Set<string>();const out:CodexMessage[]=[];
    for(let i=items.length-1;i>=0;i--){const m=items[i];const k=JSON.stringify([m.turnId,m.id]);if(!m.id||!m.turnId){throw new Error('codex_item_identity_required');}if(!seen.has(k)){seen.add(k);out.unshift(m);}}
    return out;
  }
}
export interface CodexRuntimeProof {sameServer:boolean;exclusiveWriter:boolean;taskSurvivesDisconnect:boolean;pendingRequestsRecoverable:boolean;}
export function codexCanWrite(p:CodexRuntimeProof):boolean{return p.sameServer&&p.exclusiveWriter&&p.taskSurvivesDisconnect&&p.pendingRequestsRecoverable;}
