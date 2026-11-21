export interface PreviewDevice {key:string;name:string;presence:string;platformLabel:string;current:boolean;}
export function detailSessionInvalidated(cards:PreviewDevice[],key:string,name:string,startedAt:number,updatedAt:number,failed:boolean):boolean{if(failed||updatedAt<=startedAt){return false;}const row=cards.find((card:PreviewDevice)=>card.key===key);return !row||row.name!==name||row.current||row.platformLabel!=='Windows'||row.presence==='offline';}
export interface PreviewSample {generation:number;selected:string;busy:boolean;closing:boolean;control:boolean;echo:boolean;frame:boolean;width:number;height:number;failure:string;focused:boolean;loggedIn:boolean;}
export interface PreviewRequest {key:string;name:string;surface:string;width:number;height:number;lockToken?:string;}
export interface PreviewPort {
  acquire(lock:boolean):number;owned(owner:number):boolean;select(owner:number,key:string,name:string):Promise<boolean>;
  surface(owner:number,id:string,width:number,height:number):void;join(owner:number,key:string,lock?:boolean):Promise<void>;
  sample():PreviewSample;observe(fn:()=>void):()=>void;watch():Promise<boolean>;
  bindLock(token:string,key:string,generation:number):boolean;consumeLock(token:string,key:string,generation:number):boolean;lock():Promise<string>;
  cancel(owner:number):Promise<void>;release(owner:number,id:string):Promise<void>;
}
export class PreviewView {phase:string='waiting';status:string='等待显示区域';live:boolean=false;stopping:boolean=false;}
// One explicitly confirmed request, one lease, one Surface. No background/automatic retry.
export class LivePreviewModel {
  view:PreviewView=new PreviewView();private owner:number=0;private run:number=0;private expected:number=-1;
  private request:PreviewRequest|undefined=undefined;private stopped:boolean=false;private starting:boolean=false;private watching:boolean=false;private readOnly:boolean=false;private action:boolean=false;
  private pending:Promise<void>=Promise.resolve();private stopping:Promise<void>|undefined=undefined;private off:()=>void=()=>{};
  private port:PreviewPort;private changed:(view:PreviewView)=>void;private ended:(message:string)=>void;
  constructor(port:PreviewPort,changed:(view:PreviewView)=>void,ended:(message:string)=>void){this.port=port;this.changed=changed;this.ended=ended;}
  private show(phase:string,status:string,live:boolean=false):void{this.view.phase=phase;this.view.status=status;this.view.live=live;this.changed(this.view);}
  start(request:PreviewRequest):void{
    if(this.starting||this.stopped||!request.key||(!request.lockToken&&(!request.surface||request.width<=0||request.height<=0))){return;}
    this.starting=true;this.request=request;const run=++this.run;this.owner=this.port.acquire(!!request.lockToken);
    if(!this.owner){this.show('failed','已有会话或资源正在释放，请稍后重新确认。');this.ended(this.view.status);return;}
    this.show('connecting',request.lockToken?'正在连接，等待发送一次锁屏；可随时取消。':'正在连接电脑，可随时停止。');
    this.off=this.port.observe(()=>this.sample());
    this.pending=this.connect(run,request);
  }
  private current(run:number):boolean{return !this.stopped&&run===this.run&&this.port.owned(this.owner);}
  private async connect(run:number,request:PreviewRequest):Promise<void>{
    try{
      if(!await this.port.select(this.owner,request.key,request.name)){if(this.current(run)){this.stop('设备状态已变化，未建立会话。');}return;}
      if(!this.current(run)){return;}
      if(!request.lockToken){this.port.surface(this.owner,request.surface,request.width,request.height);}
      const joining=this.port.join(this.owner,request.key,!!request.lockToken);this.expected=this.port.sample().generation;
      if(request.lockToken&&!this.port.bindLock(request.lockToken,request.key,this.expected)){this.stop('锁屏确认已失效，未发送指令。');}
      await joining;if(!this.current(run)){return;}this.sample();
    }catch(_){if(this.current(run)){this.stop('连接未完成，未生成实时画面。');}}
  }
  private sample():void{
    if(this.stopped||!this.request||!this.port.owned(this.owner)){return;}const value=this.port.sample();
    if(!value.focused||!value.loggedIn){this.stop('预览已结束：窗口失焦、进入后台或账号已退出。');return;}
    if(this.expected<0){return;}
    if(value.generation!==this.expected||value.selected!==this.request.key){this.stop('会话已变化，已停止此次请求。');return;}
    if(value.failure||(!value.busy&&!value.closing)){this.stop(value.failure?'连接未完成，未生成实时画面。':'会话已结束。');return;}
    if(this.request.lockToken){this.ready(value);return;}
    if(value.control&&!this.watching){this.watching=true;const run=this.run;this.enableReadOnly(run);}
    if(this.readOnly){this.ready(value);}
  }
  private async enableReadOnly(run:number):Promise<void>{
    try{const ok=await this.port.watch();if(!this.current(run)){return;}if(!ok){this.stop('无法开启仅观看，已停止连接。');return;}this.readOnly=true;this.ready(this.port.sample());}
    catch(_){if(this.current(run)){this.stop('只读门禁未就绪，已停止会话。');}}
  }
  private ready(value:PreviewSample):void{
    if(this.stopped||!this.request){return;}
    if(this.request.lockToken){
      if(!value.control||!value.echo||this.action){return;}this.action=true;
      if(!this.port.consumeLock(this.request.lockToken,this.request.key,this.expected)){this.stop('锁屏已取消，未发送指令。');return;}
      const run=this.run;this.sendLock(run);return;
    }
    if(value.frame){this.show('live',`仅观看 · ${value.width} × ${value.height}`,true);}
    else{this.show('connecting','已连接，正在等待电脑画面。');}
  }
  private async sendLock(run:number):Promise<void>{try{const message=await this.port.lock();if(this.current(run)){this.stop(message);}}catch(_){if(this.current(run)){this.stop('无法确认锁屏指令是否发送，请观察电脑状态。');}}}
  resize(width:number,height:number):void{if(!this.stopped&&this.request&&!this.request.lockToken&&this.port.owned(this.owner)){this.port.surface(this.owner,this.request.surface,width,height);}}
  stop(message:string='已停止此次会话。'):Promise<void>{
    if(this.stopping){return this.stopping;}this.stopped=true;this.run++;this.off();this.view.stopping=true;this.show('stopping','正在释放预览会话…');
    this.stopping=this.cleanup(message);return this.stopping;
  }
  private async cleanup(message:string):Promise<void>{
    try{await this.port.cancel(this.owner);await this.pending;await this.port.release(this.owner,this.request?.surface||'');}
    finally{this.view.stopping=false;this.show('stopped',message);this.ended(message);}
  }
}
