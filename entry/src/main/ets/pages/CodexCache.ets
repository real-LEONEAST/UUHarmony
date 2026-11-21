// SPDX-License-Identifier: GPL-3.0-only
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { CodexUtf8 } from './CodexEncoding';
import { CodexScope,codexScopeParts } from './CodexHistoryModel';
const LEAF:RegExp=/^[a-f0-9]{64}_[a-f0-9]{64}\/(?:index|[a-f0-9]{64}_[a-f0-9]{64})\.json$/;
export class CodexCache {
  private root:string='';private codec:CodexUtf8=new CodexUtf8();private static chain:Promise<void>=Promise.resolve();private static generation:number=0;private serial:number=0;
  setContext(context:common.UIAbilityContext,namespace:string='codex-history-v1'):void{if(namespace!=='codex-history-v1'&&namespace!=='terminal-notebook-v1'){throw new Error('cache_namespace');}this.root=context.filesDir+'/'+namespace;}
  private prefix(account:string,device:string):string {
    if(!this.root||![account,device].every((v:string)=>/^[a-f0-9]{64}$/.test(v))){throw new Error('codex_cache_scope');}
    return account+'_'+device+'/';
  }
  async pageKey(scope:CodexScope,cursor:string):Promise<string>{
    const parts=codexScopeParts(scope);const thread=await this.codec.hash(JSON.stringify(parts.slice(2)));
    return this.prefix(scope.account,scope.device)+thread+'_'+await this.codec.hash(cursor)+'.json';
  }
  indexKey(account:string,device:string):string{return this.prefix(account,device)+'index.json';}
  async read(key:string):Promise<string|undefined>{
    let timer:number=-1;
    try{return await Promise.race([this.readFile(key),new Promise<string|undefined>((resolve)=>{timer=setTimeout(()=>resolve(undefined),3000);})]);}
    catch(_){return undefined;}finally{if(timer>=0){clearTimeout(timer);}}
  }
  private async readFile(key:string):Promise<string|undefined>{
    if(!this.root||!LEAF.test(key)){return undefined;}
    let f:fileIo.File|undefined=undefined;
    try{
      f=await fileIo.open(this.root+'/'+key,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);const st=await fileIo.stat(f.fd);
      if(!st.isFile()||st.size<1||st.size>2*1024*1024){return undefined;}
      const bytes=new Uint8Array(st.size);let at=0;
      while(at<bytes.length){const part=new ArrayBuffer(bytes.length-at);const n=await fileIo.read(f.fd,part,{length:part.byteLength});if(n<1||n>part.byteLength){throw new Error('codex_cache_short_read');}bytes.set(new Uint8Array(part,0,n),at);at+=n;}
      return this.codec.decode(bytes);
    }catch(_){return undefined;}finally{if(f){await fileIo.close(f).catch(()=>{});}}
  }
  epoch():number{return CodexCache.generation;}
  async write(key:string,text:string,expected:number=CodexCache.generation):Promise<boolean>{
    if(!this.root||!LEAF.test(key)){return false;}
    const data=this.codec.encode(text);if(data.byteLength>2*1024*1024){return false;}
    const run=expected;let ok=false;
    const operation=CodexCache.chain.then(async()=>{
      if(run!==CodexCache.generation){return;}let f:fileIo.File|undefined=undefined;let temp='';
      try{
        if(!await fileIo.access(this.root)){await fileIo.mkdir(this.root);}
        const folder=this.root+'/'+key.split('/')[0];if(!await fileIo.access(folder)){await fileIo.mkdir(folder);}
        temp=this.root+'/'+key+'.part-'+Date.now()+'-'+(++this.serial);
        f=await fileIo.open(temp,fileIo.OpenMode.WRITE_ONLY|fileIo.OpenMode.CREATE|fileIo.OpenMode.TRUNC|fileIo.OpenMode.NOFOLLOW);
        let at=0;while(at<data.length){const part=data.slice(at);const n=await fileIo.write(f.fd,part.buffer,{length:part.byteLength});if(n<1||n>part.byteLength){throw new Error('codex_cache_short_write');}at+=n;}
        await fileIo.fsync(f.fd);await fileIo.close(f);f=undefined;
        if(run!==CodexCache.generation){return;}await fileIo.rename(temp,this.root+'/'+key);temp='';ok=true;
      }catch(_){}finally{if(f){await fileIo.close(f).catch(()=>{});}if(temp){await fileIo.unlink(temp).catch(()=>{});}}
    });CodexCache.chain=operation.catch(()=>{});await operation;return ok;
  }
  async clearComputer(account:string,device:string):Promise<boolean>{
    return this.clearPrefix(this.prefix(account,device));
  }
  async clearThread(scope:CodexScope):Promise<boolean>{
    const parts=codexScopeParts(scope);return this.clearPrefix(this.prefix(scope.account,scope.device)+await this.codec.hash(JSON.stringify(parts.slice(2)))+'_');
  }
  private async clearPrefix(prefix:string):Promise<boolean>{
    CodexCache.generation++;let ok=true;
    const operation=CodexCache.chain.then(async()=>{
      try{if(!await fileIo.access(this.root)){return;}
        const parts=prefix.split('/');const directory=this.root+'/'+parts[0];if(!await fileIo.access(directory)){return;}
        for(const name of await fileIo.listFile(directory)){const key=parts[0]+'/'+name;if(LEAF.test(key.replace(/\.part-\d{1,16}-\d{1,10}$/,''))&&key.startsWith(prefix)){await fileIo.unlink(directory+'/'+name);}}
      }catch(_){ok=false;}
    });CodexCache.chain=operation.catch(()=>{});await operation;return ok;
  }
}
