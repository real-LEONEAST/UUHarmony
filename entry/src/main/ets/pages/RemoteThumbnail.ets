import { image } from '@kit.ImageKit';
import { client, AuthView } from './AuthClient';
interface DesktopThumbnail {key:string;pixels:image.PixelMap;capturedAt:number;}
// Memory only: no desktop image survives logout or process exit.
class RemoteThumbnails {
  private rows:DesktopThumbnail[]=[];
  private observers:Map<number,(version:number)=>void>=new Map();private nextObserver:number=0;
  private capturePending:boolean=false;private captureKey:string='';private captureSession:number=-1;private capturedAt:number=0;
  generation:number=0;
  version:number=0;
  constructor(){client.monitor((view:AuthView)=>{if(!view.loggedIn){this.clear();}});}
  private release(pixels:image.PixelMap):void{pixels.release().catch(()=>{});}
  observe(observer:(version:number)=>void):()=>void{const id=++this.nextObserver;this.observers.set(id,observer);observer(this.version);return ()=>{this.observers.delete(id);};}
  private emit():void{this.version++;this.observers.forEach((observer:(version:number)=>void)=>observer(this.version));}
  clear():void{this.generation++;for(const row of this.rows){this.release(row.pixels);}this.rows=[];this.captureKey='';this.captureSession=-1;this.capturedAt=0;this.emit();}
  get(key:string):DesktopThumbnail|undefined{return this.rows.find((row:DesktopThumbnail)=>row.key===key);}
  save(key:string,pixels:image.PixelMap,generation:number):boolean{
    if(!client.view.loggedIn||generation!==this.generation||!key){this.release(pixels);return false;}
    const old=this.get(key);if(old){this.release(old.pixels);}this.rows=this.rows.filter((row:DesktopThumbnail)=>row.key!==key);
    if(this.rows.length>=12){this.release(this.rows[0].pixels);this.rows.shift();}
    this.rows.push({key:key,pixels:pixels,capturedAt:Date.now()});this.emit();return true;
  }
  // Called only for an already rendered, authorized foreground remote Surface.
  // Never opens a session or reads another window. One capture at most every 15s.
  async captureRendered(key:string,surface:string,sessionGeneration:number,width:number,height:number,current:()=>boolean):Promise<boolean>{
    if(this.capturePending||!key||!surface||!client.view.loggedIn||!current()||width<=0||height<=0||width>8192||height>8192||width*height>16777216){return false;}
    const now=Date.now();if(this.captureKey===key&&this.captureSession===sessionGeneration&&now>=this.capturedAt&&now-this.capturedAt<15000){return false;}
    this.capturePending=true;this.captureKey=key;this.captureSession=sessionGeneration;this.capturedAt=now;const generation=this.generation;let pixels:image.PixelMap|undefined=undefined;
    try{
      pixels=await image.createPixelMapFromSurface(surface);
      const info=await pixels.getImageInfo();
      if(info.size.width<=0||info.size.height<=0||info.size.width>8192||info.size.height>8192||info.size.width*info.size.height>16777216||!current()||generation!==this.generation){this.release(pixels);pixels=undefined;return false;}
      const scale=Math.min(1,480/Math.max(info.size.width,info.size.height));if(scale<1){await pixels.scale(scale,scale);}
      if(!current()||generation!==this.generation){this.release(pixels);pixels=undefined;return false;}
      const saved=this.save(key,pixels,generation);pixels=undefined;return saved;
    }catch(_){if(pixels){this.release(pixels);}return false;}finally{this.capturePending=false;}
  }
  label(key:string):string{const row=this.get(key);return row?'上次预览 '+new Date(row.capturedAt).toLocaleString():'暂无设备预览';}
}
export const remoteThumbnails:RemoteThumbnails=new RemoteThumbnails();
