import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
const DISK_BYTES:number=1024*1024;
const CACHE_FILE:RegExp=/^v1_[a-f0-9]{64}_[a-f0-9]{64}_[a-f0-9]{64}\.png$/;
interface CacheFile {name:string;modified:number;}
export interface CachedWallpaper {data:ArrayBuffer;storedAt:number;revision:string;}
// Only normalized published wallpapers enter here. Video/Surface frames never do.
export class WallpaperDiskCache {
  private root:string='';private serial:number=0;
  setContext(context:common.UIAbilityContext):void{this.root=context.filesDir+'/device-wallpapers-v1';}
  private path(account:string,key:string,revision:string):string{
    if(!this.root||![account,key,revision].every((value:string)=>/^[a-f0-9]{64}$/.test(value))){throw new Error('wallpaper_cache_scope_required');}
    return this.root+'/v1_'+account+'_'+key+'_'+revision+'.png';
  }
  async read(account:string,key:string,revision:string):Promise<ArrayBuffer|undefined>{return (await this.record(account,key,revision))?.data;}
  async record(account:string,key:string,revision:string):Promise<CachedWallpaper|undefined>{
    let file:fileIo.File|undefined=undefined;
    try{const path=this.path(account,key,revision);if(!await fileIo.access(path)){return undefined;}file=await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
      const stat=await fileIo.stat(file.fd);if(!stat.isFile()||stat.size<=0||stat.size>DISK_BYTES){return undefined;}
      const data=new ArrayBuffer(stat.size);let offset=0;
      while(offset<stat.size){const part=new ArrayBuffer(stat.size-offset);const count=await fileIo.read(file.fd,part,{length:part.byteLength});if(count<=0||count>part.byteLength){return undefined;}new Uint8Array(data).set(new Uint8Array(part,0,count),offset);offset+=count;}
      return {data:data,storedAt:stat.mtime<100000000000?stat.mtime*1000:stat.mtime,revision:revision};
    }catch(_){return undefined;}finally{if(file){await fileIo.close(file).catch(()=>{});}}
  }
  async latest(account:string,key:string,excludeRevision:string):Promise<CachedWallpaper|undefined>{
    try{this.path(account,key,excludeRevision);if(!await fileIo.access(this.root)){return undefined;}const prefix='v1_'+account+'_'+key+'_';const names=await fileIo.listFile(this.root);const files:CacheFile[]=[];
      for(const name of names){if(CACHE_FILE.test(name)&&name.startsWith(prefix)&&!name.endsWith('_'+excludeRevision+'.png')){const stat=await fileIo.stat(this.root+'/'+name);if(stat.isFile()){files.push({name:name,modified:stat.mtime});}}}
      files.sort((a:CacheFile,b:CacheFile)=>b.modified-a.modified);
      for(const file of files){const record=await this.record(account,key,file.name.slice(-68,-4));if(record){return record;}}
    }catch(_){}return undefined;
  }
  async write(account:string,key:string,revision:string,data:ArrayBuffer):Promise<void>{
    if(data.byteLength===0||data.byteLength>DISK_BYTES){return;}
    let file:fileIo.File|undefined=undefined;let temporary:string='';
    try{const destination=this.path(account,key,revision);if(!await fileIo.access(this.root)){await fileIo.mkdir(this.root);}
      temporary=destination+'.part-'+Date.now()+'-'+(++this.serial);
      file=await fileIo.open(temporary,fileIo.OpenMode.READ_WRITE|fileIo.OpenMode.CREATE|fileIo.OpenMode.TRUNC|fileIo.OpenMode.NOFOLLOW);
      let offset=0;while(offset<data.byteLength){const part=data.slice(offset);const count=await fileIo.write(file.fd,part,{length:part.byteLength});if(count<=0||count>part.byteLength){throw new Error('wallpaper_cache_short_write');}offset+=count;}
      await fileIo.fsync(file.fd);await fileIo.close(file);file=undefined;await fileIo.rename(temporary,destination);temporary='';await this.prune();
    }catch(_){}finally{if(file){await fileIo.close(file).catch(()=>{});}if(temporary){await fileIo.unlink(temporary).catch(()=>{});}}
  }
  private async prune():Promise<void>{
    const names=await fileIo.listFile(this.root);const files:CacheFile[]=[];
    for(const name of names){if(CACHE_FILE.test(name)){const stat=await fileIo.stat(this.root+'/'+name);if(stat.isFile()){files.push({name:name,modified:stat.mtime});}}}
    files.sort((a:CacheFile,b:CacheFile)=>b.modified-a.modified);
    // Only this cache's exact versioned, hashed leaves; never a caller/user path.
    for(const file of files.slice(32)){await fileIo.unlink(this.root+'/'+file.name).catch(()=>{});}
  }
}
