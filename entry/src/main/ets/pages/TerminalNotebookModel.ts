// SPDX-License-Identifier: GPL-3.0-only
// A local observation record is deliberately not a Codex thread or a Windows user identity.
export interface NotebookMeta {id:string;account:string;device:string;computer:string;name:string;createdAt:number;updatedAt:number;session:number;partial:boolean;}
export interface NotebookIndex {version:number;account:string;device:string;records:NotebookMeta[];}
export interface NotebookScreen {snapshot:string;plain:string;cols:number;rows:number;}
export interface NotebookRecord {version:number;meta:NotebookMeta;screen:NotebookScreen;}
export interface NotebookRaw {error?:string;session?:number;sessionToken?:number;streamEpoch?:number;cursor?:number;nextCursor?:number;base64?:string;}
export function notebookScope(account:string,device:string):void {
 if(!/^[a-f0-9]{64}$/.test(account)||!/^[a-f0-9]{64}$/.test(device)){throw new Error('notebook_scope');}
}
export function notebookMeta(meta:NotebookMeta,account:string,device:string):boolean {
 return !!meta&&meta.account===account&&meta.device===device&&/^[a-f0-9-]{36}$/.test(meta.id)&&typeof meta.name==='string'&&meta.name.length<=120&&typeof meta.computer==='string'&&meta.computer.length<=160&&Number.isSafeInteger(meta.createdAt)&&meta.createdAt>0&&Number.isSafeInteger(meta.updatedAt)&&meta.updatedAt>=meta.createdAt&&Number.isSafeInteger(meta.session)&&meta.session>=0&&typeof meta.partial==='boolean';
}
export function notebookIndex(index:NotebookIndex,account:string,device:string):NotebookMeta[] {
 notebookScope(account,device);if(!index||index.version!==1||index.account!==account||index.device!==device||!Array.isArray(index.records)){return [];}
 const seen:Set<string>=new Set<string>();return index.records.filter((meta:NotebookMeta)=>{if(!notebookMeta(meta,account,device)||seen.has(meta.id)){return false;}seen.add(meta.id);return true;}).sort((a:NotebookMeta,b:NotebookMeta)=>b.updatedAt-a.updatedAt).slice(0,64);
}
export function notebookScreen(screen:NotebookScreen):boolean {
 return !!screen&&typeof screen.snapshot==='string'&&screen.snapshot.length<=450000&&typeof screen.plain==='string'&&screen.plain.length<=150000&&Number.isSafeInteger(screen.cols)&&screen.cols>=2&&screen.cols<=240&&Number.isSafeInteger(screen.rows)&&screen.rows>=2&&screen.rows<=100;
}
export function notebookRedact(text:string):string {
 return text.replace(/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi,'Bearer [redacted]').replace(/\bsk-[A-Za-z0-9_-]{12,}/g,'[redacted]').replace(/((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|authorization|cookie)\s*[:=]\s*)[^\s,;}]+/gi,'$1[redacted]');
}
export function notebookInputChunks(text:string):string[] {
 if(!text||text.length>4096||text.includes('\u0000')){throw new Error('notebook_input_limit');}
 const chunks:string[]=[];let at=0;while(at<text.length){let end=Math.min(text.length,at+2048);const code=text.charCodeAt(end-1);if(end<text.length&&code>=0xd800&&code<=0xdbff){end--;}
  chunks.push(text.slice(at,end));at=end;
 }return chunks;
}
// ArkWeb releases may JSON-encode a JavaScript string result once more.
export function notebookWebString(value:string):string {return value.startsWith('"')?JSON.parse(value) as string:value;}
export class NotebookCursor {
 cursor:number=0;epoch:number=0;private pending:number=-1;
 constructor(private session:number,private token:number){}
 accept(reply:NotebookRaw,byteLength:number):void {
  if(this.pending>=0||reply.error||reply.session!==this.session||reply.sessionToken!==this.token||reply.cursor!==this.cursor||!Number.isSafeInteger(reply.streamEpoch)||reply.streamEpoch!<0||this.epoch!==0&&this.epoch!==reply.streamEpoch||!Number.isSafeInteger(reply.nextCursor)||reply.nextCursor!==this.cursor+byteLength||byteLength<0||byteLength>16384){throw new Error('notebook_stream_changed');}
  this.epoch=reply.streamEpoch!;this.pending=reply.nextCursor!;
 }
 commit():void {if(this.pending<0){throw new Error('notebook_render_not_pending');}this.cursor=this.pending;this.pending=-1;}
 waiting():boolean{return this.pending>=0;}
}
