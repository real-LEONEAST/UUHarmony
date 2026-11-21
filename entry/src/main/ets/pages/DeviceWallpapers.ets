import { WallpaperDiskCache } from './WallpaperDiskCache';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { invoke } from 'libs3c.so';
import { client, AuthView } from './AuthClient';
import { DeviceCard } from './DeviceListModel';
import { trustedWallpaperUrl, wallpaperFormat, wallpaperSize, WALLPAPER_BYTES } from './WallpaperPolicy';

interface WallpaperCommand {op:string;deviceKey:string;revision:string;}
interface WallpaperReply {url?:string;revision?:string;error?:string;}
interface WallpaperEntry {key:string;revision:string;state:string;reason?:string;previous?:boolean;pixels?:image.PixelMap;loadedAt:number;}

// Service wallpapers only. Independent of video/session/screen capture and account HTTP headers.
// Twelve in-memory thumbnails plus account/device/revision-isolated normalized disk cache.
class DeviceWallpapers {
  version:number=0;
  private entries:WallpaperEntry[]=[];
  private disk:WallpaperDiskCache=new WallpaperDiskCache();
  private accountKey:string='';
  private sourceStates:Map<string,string>=new Map();
  private visible:boolean=false;
  private generation:number=0;
  private pumping:boolean=false;
  private active:http.HttpRequest|undefined=undefined;
  private activeEntry:WallpaperEntry|undefined=undefined;
  private refreshes:number=-1;
  private observers:Map<number,(version:number)=>void>=new Map();
  private nextObserver:number=0;
  constructor(){client.monitor((view:AuthView)=>{const key=view.loggedIn&&view.wallpaperAccountKey&&/^[a-f0-9]{64}$/.test(view.wallpaperAccountKey)?view.wallpaperAccountKey:'';if(key!==this.accountKey){this.accountKey=key;this.clear();}if(!view.loggedIn||view.suspended){this.clear();}});}
  setContext(context:common.UIAbilityContext):void{this.disk.setContext(context);}
  observe(observer:(version:number)=>void):()=>void{const id=++this.nextObserver;this.observers.set(id,observer);observer(this.version);return ()=>{this.observers.delete(id);};}
  private emit():void{this.version++;this.observers.forEach((observer:(version:number)=>void)=>observer(this.version));}
  private release(entry:WallpaperEntry):void{if(entry.pixels){entry.pixels.release().catch(()=>{});entry.pixels=undefined;}}
  private clear():void{this.generation++;if(this.active){try{this.active.destroy();}catch(_){}this.active=undefined;}for(const entry of this.entries){this.release(entry);}this.entries=[];this.sourceStates.clear();this.emit();}
  setVisible(value:boolean):void{if(this.visible===value){return;}this.visible=value;if(!value){this.clear();}}
  sync(cards:DeviceCard[],refreshes:number,selectedKey:string=''):void{
    if(!this.visible||!client.view.loggedIn||client.view.suspended){return;}
    this.sourceStates.clear();for(const card of cards){this.sourceStates.set(card.key,card.wallpaperState||'none');}
    const ordered=cards.filter((card:DeviceCard)=>card.wallpaperRevision.length===64);
    const selected=ordered.find((card:DeviceCard)=>card.key===selectedKey);
    const wanted=(selected?[selected].concat(ordered.filter((card:DeviceCard)=>card.key!==selectedKey)):ordered).slice(0,12);
    const retry=refreshes!==this.refreshes;this.refreshes=refreshes;
    if(this.activeEntry&&!wanted.some((card:DeviceCard)=>card.key===this.activeEntry?.key&&card.wallpaperRevision===this.activeEntry?.revision)){try{this.active?.destroy();}catch(_){}}
    for(const entry of this.entries){if(!wanted.some((card:DeviceCard)=>card.key===entry.key)){this.release(entry);}}
    this.entries=wanted.map((card:DeviceCard)=>{
      const old=this.entries.find((entry:WallpaperEntry)=>entry.key===card.key&&entry.revision===card.wallpaperRevision);
      if(old){if(retry&&old.state==='failed'){old.state='queued';}return old;}
      const previous=this.entries.find((entry:WallpaperEntry)=>entry.key===card.key);const fresh:WallpaperEntry={key:card.key,revision:card.wallpaperRevision,state:'queued',loadedAt:previous?.loadedAt||0,pixels:previous?.pixels,previous:!!previous?.pixels,reason:previous?.pixels?'previous_revision_memory':''};if(previous){previous.pixels=undefined;}return fresh;
    });
    this.pump();
  }
  get(key:string):image.PixelMap|undefined{return this.entries.find((entry:WallpaperEntry)=>entry.key===key)?.pixels;}
  reason(key:string):string{const entry=this.entries.find((row:WallpaperEntry)=>row.key===key);return entry?.reason||entry?.state||this.sourceStates.get(key)||'none';}
  label(key:string):string{const entry=this.entries.find((row:WallpaperEntry)=>row.key===key);return entry?.pixels?(entry.previous?'上次设备壁纸 · 非实时桌面':'设备上报壁纸 · 非实时桌面'):entry?.state==='loading'?'设备壁纸加载中':entry?.state==='failed'?'':'';}
  private current(entry:WallpaperEntry,run:number):boolean{return this.visible&&run===this.generation&&client.view.loggedIn&&!client.view.suspended&&this.entries.includes(entry);}
  private async load(entry:WallpaperEntry,run:number):Promise<void>{
    const account=this.accountKey;
    if(account){
      const cached=await this.disk.record(account,entry.key,entry.revision);
      if(cached&&this.current(entry,run)&&wallpaperFormat(new Uint8Array(cached.data))){try{await this.install(cached.data,entry,run);if(this.current(entry,run)){entry.reason='disk_cache';this.emit();const age=Date.now()-cached.storedAt;if(age>=0&&age<6*60*60*1000){return;}}}catch(_){}}
      if(!entry.pixels&&this.current(entry,run)){const previous=await this.disk.latest(account,entry.key,entry.revision);if(previous&&this.current(entry,run)&&wallpaperFormat(new Uint8Array(previous.data))){try{await this.install(previous.data,entry,run);if(this.current(entry,run)){entry.previous=true;entry.reason='previous_revision_cache';this.emit();}}catch(_){}}}
    }
    if(!this.current(entry,run)){return;}
    if(deviceInfo.sdkApiVersion<23){throw new Error('wallpaper_redirect_policy_unavailable');}
    const command:WallpaperCommand={op:'device_wallpaper',deviceKey:entry.key,revision:entry.revision};
    const resolved=JSON.parse(await invoke(JSON.stringify(command))) as WallpaperReply;
    if(!this.current(entry,run)){return;}
    if(resolved.error||resolved.revision!==entry.revision||!resolved.url||!trustedWallpaperUrl(resolved.url)){throw new Error('wallpaper_source_unavailable');}
    const request=http.createHttp();this.active=request;this.activeEntry=entry;let timer:number=-1;
    try{
      // Never pass signed NRD headers, account tokens, cookies, or a Referer.
      const headers:Record<string,string>={'Accept':'image/png,image/jpeg,image/webp'};
      const options:http.HttpRequestOptions={method:http.RequestMethod.GET,header:headers,expectDataType:http.HttpDataType.ARRAY_BUFFER,connectTimeout:5000,readTimeout:8000,usingCache:false,maxLimit:WALLPAPER_BYTES,maxRedirects:0};
      const response=await Promise.race([request.request(resolved.url,options),new Promise<http.HttpResponse>((resolve,reject)=>{timer=setTimeout(()=>{try{request.destroy();}catch(_){}reject(new Error('wallpaper_deadline'));},10000);})]);
      if(!this.current(entry,run)){return;}
      if(response.responseCode!==200||!(response.result instanceof ArrayBuffer)||response.result.byteLength===0||response.result.byteLength>WALLPAPER_BYTES){throw new Error('wallpaper_response_rejected');}
      const bytes=new Uint8Array(response.result);if(!wallpaperFormat(bytes)){throw new Error('wallpaper_format_rejected');}
      await this.install(response.result,entry,run);
      if(this.current(entry,run)&&entry.pixels&&account){
        const packer=image.createImagePacker();
        try{const option:image.PackingOption={format:'image/png',quality:100};const normalized=await packer.packing(entry.pixels,option);if(this.current(entry,run)&&account===this.accountKey){await this.disk.write(account,entry.key,entry.revision,normalized);}}
        catch(_){}finally{await packer.release().catch(()=>{});}
      }
    }finally{if(timer>=0){clearTimeout(timer);}try{request.destroy();}catch(_){}if(this.active===request){this.active=undefined;this.activeEntry=undefined;}}
  }
  private async install(data:ArrayBuffer,entry:WallpaperEntry,run:number):Promise<void>{
    const source=image.createImageSource(data);
    try{const info=await source.getImageInfo();if(!this.current(entry,run)){return;}
      if(!wallpaperSize(info.size.width,info.size.height)){throw new Error('wallpaper_dimensions_rejected');}
      const scale=Math.min(1,480/Math.max(info.size.width,info.size.height));const size:image.Size={width:Math.max(1,Math.round(info.size.width*scale)),height:Math.max(1,Math.round(info.size.height*scale))};
      const decoding:image.DecodingOptions={desiredSize:size,editable:false};const pixels=await source.createPixelMap(decoding);
      if(!this.current(entry,run)){await pixels.release().catch(()=>{});return;}
      this.release(entry);entry.pixels=pixels;entry.loadedAt=Date.now();entry.state='ready';entry.reason='';entry.previous=false;
    }finally{await source.release().catch(()=>{});}
  }
  private async pump():Promise<void>{
    if(this.pumping||!this.visible){return;}this.pumping=true;
    try{
      let entry=this.entries.find((row:WallpaperEntry)=>row.state==='queued');
      while(entry&&this.visible){const run=this.generation;entry.state='loading';try{await this.load(entry,run);}catch(error){if(this.current(entry,run)){entry.state=entry.pixels?'ready':'failed';const code=error instanceof Error?error.message:'';entry.reason=['wallpaper_redirect_policy_unavailable','wallpaper_source_unavailable','wallpaper_deadline','wallpaper_response_rejected','wallpaper_format_rejected','wallpaper_dimensions_rejected'].includes(code)?code:'wallpaper_transport_or_decode_failed';}}if(this.current(entry,run)){this.emit();}entry=this.entries.find((row:WallpaperEntry)=>row.state==='queued');}
    }finally{this.pumping=false;}
  }
}
export const deviceWallpapers:DeviceWallpapers=new DeviceWallpapers();
