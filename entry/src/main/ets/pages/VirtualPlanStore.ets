import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { VirtualPlan } from './VirtualKeyModel';
import { validateVirtualPlan } from './VirtualPlanValidation';
import { publicVirtualPlan } from './PublicVirtualPlan';
import { upgradeKnownVirtualPlan } from './VirtualPlanUpgrade';
interface SelectionRecord {id:string;}
export interface CurrentVirtualPlan {state:string; item?:StoredVirtualPlan;}
export interface StoredVirtualPlan {id:string; name:string; rawSha256:string; sourceVersion:string; plan:VirtualPlan;}
export class VirtualPlanStore {
 private root:string='';private scope:string='offline';private serial:number=0;private currentScope:()=>string;private static writes:Promise<void>=Promise.resolve();
 constructor(context:common.UIAbilityContext,account:string,currentScope:()=>string){this.root=context.filesDir+'/virtual-plans-v1';this.scope=/^[a-f0-9]{64}$/.test(account)?account:'offline';this.currentScope=currentScope;}
 private allowed():boolean{return this.currentScope()===this.scope;}
 private folder():string{return this.root+'/'+this.scope;}
 private validId(id:string):boolean{return /^[a-z0-9-]{1,80}$/.test(id);}
 private async ensure():Promise<void>{if(!await fileIo.access(this.root)){await fileIo.mkdir(this.root);}if(!await fileIo.access(this.folder())){await fileIo.mkdir(this.folder());}}
 private async write(name:string,text:string,replace:boolean):Promise<boolean>{
  const operation=VirtualPlanStore.writes.then(()=>this.writeNow(name,text,replace));
  VirtualPlanStore.writes=operation.then(()=>{},()=>{});return operation;
 }
 private async writeNow(name:string,text:string,replace:boolean):Promise<boolean>{
  if(!this.allowed()||!/^[a-z0-9-]+\.(plan|source|draft|choice)\.json$/.test(name)){return false;}const bytes=new util.TextEncoder().encodeInto(text);if(bytes.length>1048576){return false;}
  let file:fileIo.File|undefined=undefined;let temp='';
  try{await this.ensure();const target=this.folder()+'/'+name;if(!replace&&await fileIo.access(target)){return false;}
   temp=target+'.tmp-'+Date.now()+'-'+(++this.serial);file=await fileIo.open(temp,fileIo.OpenMode.WRITE_ONLY|fileIo.OpenMode.CREATE|fileIo.OpenMode.NOFOLLOW);
   let offset=0;while(offset<bytes.length){const part=bytes.slice(offset);const n=await fileIo.write(file.fd,part.buffer,{length:part.byteLength});if(n<=0||n>part.length){throw Error('write');}offset+=n;}
   await fileIo.fsync(file.fd);await fileIo.close(file);file=undefined;if(!this.allowed()){return false;}if(!replace&&await fileIo.access(target)){return false;}await fileIo.rename(temp,target);temp='';return true;
  }catch(_){return false;}finally{if(file){await fileIo.close(file).catch(()=>{});}if(temp){await fileIo.unlink(temp).catch(()=>{});}bytes.fill(0);}
 }
 private async read(name:string):Promise<string>{
  if(!this.allowed()||!/^[a-z0-9-]+\.(plan|source|draft|choice)\.json$/.test(name)){return '';}let file:fileIo.File|undefined=undefined;
  try{file=await fileIo.open(this.folder()+'/'+name,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);const st=await fileIo.stat(file.fd);if(!st.isFile()||st.size<1||st.size>1048576){return '';}
   const bytes=new Uint8Array(st.size);let offset=0;while(offset<bytes.length){const buf=new ArrayBuffer(bytes.length-offset);const n=await fileIo.read(file.fd,buf,{length:buf.byteLength});if(n<=0||n>buf.byteLength){return '';}bytes.set(new Uint8Array(buf,0,n),offset);offset+=n;}return util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(bytes);
  }catch(_){return '';}finally{if(file){await fileIo.close(file).catch(()=>{});}}
 }
 async list():Promise<StoredVirtualPlan[]>{
  try{if(!await fileIo.access(this.folder())){return [];}const names=await fileIo.listFile(this.folder());if(names.length>512){return [];}
   const result:StoredVirtualPlan[]=[];for(const name of names){if(!/^[a-z0-9-]+\.plan\.json$/.test(name)){continue;}const item=await this.load(name.slice(0,-10));if(item){result.push(item);}}return result;
  }catch(_){return [];}
 }
 async load(id:string):Promise<StoredVirtualPlan|undefined>{if(!this.validId(id)){return undefined;}try{const text=await this.read(id+'.plan.json');if(!text){return undefined;}const item=JSON.parse(text) as StoredVirtualPlan;if(item.id!==id||!item.plan||item.name!==item.plan.name||typeof item.sourceVersion!=='string'||item.sourceVersion.length>128||!/^[a-f0-9]{64}$/.test(item.rawSha256)){return undefined;}const clean=publicVirtualPlan(item.plan);if(!clean){return undefined;}item.plan=clean;const raw=await this.source(item);if(!raw||!this.allowed()){return undefined;}item.plan=upgradeKnownVirtualPlan(item.plan,raw,item.rawSha256);return item;}catch(_){return undefined;}}
 async create(raw:string,plan:VirtualPlan,sourceVersion:string=''):Promise<StoredVirtualPlan|undefined>{
  const clean=publicVirtualPlan(plan);if(!clean||sourceVersion.length>128||/[^a-zA-Z0-9._-]/.test(sourceVersion)){return undefined;}plan=clean;const bytes=new util.TextEncoder().encodeInto(raw);if(!bytes.length||bytes.length>1048576){return undefined;}const md=cryptoFramework.createMd('SHA256');await md.update({data:bytes});const digest=await md.digest();let hash='';digest.data.forEach((v:number)=>{hash+=v.toString(16).padStart(2,'0');});bytes.fill(0);
  const id='plan-'+Date.now().toString(36)+'-'+(++this.serial).toString(36);const item:StoredVirtualPlan={id:id,name:plan.name,rawSha256:hash,sourceVersion:sourceVersion,plan:plan};
  if(!await this.write(id+'.source.json',raw,false)){return undefined;}if(!await this.write(id+'.plan.json',JSON.stringify(item),false)){return undefined;}return item;
 }
 async save(item:StoredVirtualPlan,plan:VirtualPlan):Promise<boolean>{const clean=publicVirtualPlan(plan);if(!this.validId(item.id)||!clean||!/^[a-f0-9]{64}$/.test(item.rawSha256)){return false;}plan=clean;if(!await this.source(item)||!this.allowed()){return false;}const next:StoredVirtualPlan={id:item.id,name:plan.name,rawSha256:item.rawSha256,sourceVersion:item.sourceVersion,plan:plan};return this.write(item.id+'.plan.json',JSON.stringify(next),true);}
 async select(id:string):Promise<boolean>{
  if(!this.validId(id)||!this.allowed()){return false;}const item=await this.load(id);if(!item||!this.allowed()){return false;}
  const record:SelectionRecord={id:id};return this.write('selection.choice.json',JSON.stringify(record),true);
 }
 async current():Promise<CurrentVirtualPlan>{
  try{
   if(!this.allowed()){return {state:'invalid'};}
   if(!await fileIo.access(this.folder()+'/selection.choice.json')){return {state:'none'};}
   const raw=await this.read('selection.choice.json');if(!raw||!this.allowed()){return {state:'invalid'};}
   const value=JSON.parse(raw) as SelectionRecord;if(!value||!this.validId(value.id)){return {state:'invalid'};}
   const item=await this.load(value.id);if(!item||!this.allowed()){return {state:'invalid'};}return {state:'ready',item:item};
  }catch(_){return {state:'invalid'};}
 }
 async saveDraft(item:StoredVirtualPlan,plan:VirtualPlan):Promise<boolean>{const clean=publicVirtualPlan(plan);if(!this.validId(item.id)||!clean){return false;}return this.write(item.id+'.draft.json',JSON.stringify(clean),true);}
 async loadDraft(item:StoredVirtualPlan):Promise<VirtualPlan|undefined>{if(!this.validId(item.id)){return undefined;}try{const data=await this.read(item.id+'.draft.json');if(!data){return undefined;}const plan=JSON.parse(data) as VirtualPlan;return publicVirtualPlan(plan);}catch(_){return undefined;}}
 async source(item:StoredVirtualPlan):Promise<string>{
  if(!this.validId(item.id)||!/^[a-f0-9]{64}$/.test(item.rawSha256)){return '';}
  const raw=await this.read(item.id+'.source.json');if(!raw||!this.allowed()){return '';}
  const bytes=new util.TextEncoder().encodeInto(raw);const md=cryptoFramework.createMd('SHA256');await md.update({data:bytes});const digest=await md.digest();bytes.fill(0);let hash='';digest.data.forEach((v:number)=>{hash+=v.toString(16).padStart(2,'0');});return this.allowed()&&hash===item.rawSha256?raw:'';
 }
}
