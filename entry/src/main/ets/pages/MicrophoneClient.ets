import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import micNative from 'libuumic.so';

export interface MicrophoneEvent {action:string;permissionGranted?:boolean;foreground?:boolean;generation?:number;timestamp?:number;base64?:string;}
export interface MicrophoneCommand {op:string;event:MicrophoneEvent;}
interface MicrophoneReply {generation:number;enabled:boolean;pending:boolean;negotiated:boolean;stereo:boolean;packetMs:number;captureAllowed:boolean;remoteAck:boolean|null;remoteActive:boolean;sentPackets:number;error?:string|null;}
interface CaptureReply {generation?:number;running?:boolean;error?:number;interrupt?:number;}
interface CapturedPacket {generation:number;available:boolean;base64:string;timestamp:number;samples:number;error?:number;}
export class MicrophoneView {
  state:string='off';text:string='麦克风未开启';enabled:boolean=false;pending:boolean=false;capturing:boolean=false;sentPackets:number=0;remoteAck:boolean|null=null;remoteActive:boolean=false;error:string='';
}

// Session-owned. Opening/closing the settings panel never starts or stops recording.
// The owner revokes on background, watch mode, disconnect or explicit user close.
export class MicrophoneClient {
  view:MicrophoneView=new MicrophoneView();
  private send:(command:MicrophoneCommand)=>Promise<string>;
  private context:common.UIAbilityContext|undefined=undefined;
  private observer:((view:MicrophoneView)=>void)|undefined=undefined;
  private foreground:boolean=false;
  private controlAllowed:boolean=false;
  private epoch:number=0;
  private generation:number=0;
  private timer:number=-1;
  private busy:boolean=false;
  private intended:boolean=false;
  private deadline:number=0;
  private disposed:boolean=false;
  constructor(send:(command:MicrophoneCommand)=>Promise<string>){this.send=send;}
  setContext(context:common.UIAbilityContext):void{this.context=context;}
  observe(observer:((view:MicrophoneView)=>void)|undefined):void{this.observer=observer;this.emit();}
  setForeground(value:boolean):void{if(value===this.foreground){return;}this.foreground=value;if(!value){this.disable();}}
  setControlAllowed(value:boolean):void{if(value===this.controlAllowed){return;}this.controlAllowed=value;if(!value){this.disable();}}
  private emit():void{if(this.observer){this.observer(this.view);}}
  private current(run:number):boolean{return !this.disposed&&run===this.epoch&&this.foreground&&this.controlAllowed;}
  private stopTimer():void{if(this.timer>=0){clearInterval(this.timer);this.timer=-1;}}
  private stopLocal():void{this.intended=false;this.deadline=0;this.stopTimer();try{micNative.stop();}catch(_){}this.generation=0;this.view.enabled=false;this.view.pending=false;this.view.capturing=false;}
  private async command(event:MicrophoneEvent):Promise<MicrophoneReply>{return JSON.parse(await this.send({op:'peer_microphone',event:event})) as MicrophoneReply;}
  async enable():Promise<void>{
    if(this.busy||this.view.enabled||!this.foreground||!this.controlAllowed||this.disposed){return;}
    const context=this.context;if(!context){this.view.text='麦克风授权窗口尚未就绪';this.emit();return;}
    const run=++this.epoch;this.busy=true;this.intended=true;
    try{
      const available=await this.command({action:'status'});if(!this.current(run)){return;}
      if(available.error||!available.negotiated){throw new Error('microphone_audio_negotiation_unsupported');}
      // This is the only permission prompt and can only be reached by explicit enable().
      const permission=await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context,['ohos.permission.MICROPHONE']);
      if(!this.current(run)){return;}
      if(permission.authResults.length!==1||permission.authResults[0]!==abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED){throw new Error('microphone_permission_denied');}
      const state=await this.command({action:'request',permissionGranted:true,foreground:true});
      if(!this.current(run)){await this.command({action:'stop'}).catch(()=>undefined);return;}
      if(state.error||!state.enabled){throw new Error(state.error||'microphone_request_failed');}
      this.deadline=Date.now()+11000;this.generation=state.generation;this.view.enabled=true;this.view.pending=true;this.view.state='waiting';this.view.error='';this.view.text='等待电脑确认麦克风策略和虚拟麦克风就绪；尚未采集';this.emit();
      this.timer=setInterval(()=>{this.refresh();},80);
    }catch(_){if(run===this.epoch){this.stopLocal();await this.command({action:'stop'}).catch(()=>undefined);this.view.state='error';this.view.text='麦克风未开启：请检查系统授权和电脑的 Opus/虚拟麦克风支持。';this.emit();}}
    finally{this.busy=false;}
  }
  async refresh():Promise<void>{
    if(this.busy||!this.view.enabled||!this.foreground||!this.controlAllowed||this.disposed){return;}
    const run=this.epoch;this.busy=true;
    try{
      if(this.deadline>0&&Date.now()>=this.deadline){throw new Error('microphone_remote_confirmation_timeout');}
      const context=this.context;if(!context){throw new Error('microphone_context_missing');}
      if(abilityAccessCtrl.createAtManager().checkAccessTokenSync(context.applicationInfo.accessTokenId,'ohos.permission.MICROPHONE')!==abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED){throw new Error('microphone_permission_revoked');}
      const state=await this.command({action:'status'});if(!this.current(run)){return;}
      if(state.error||!state.enabled||state.generation!==this.generation){throw new Error('microphone_session_or_policy_revoked');}
      this.view.remoteAck=state.remoteAck;this.view.remoteActive=state.remoteActive;this.view.pending=state.pending;this.view.sentPackets=state.sentPackets;
      if(state.captureAllowed){
        this.deadline=0;
        if(!this.view.capturing){const capture=JSON.parse(micNative.start(state.generation,state.stereo,state.packetMs)) as CaptureReply;if(capture.error||!capture.running){throw new Error('microphone_capture_start_failed');}this.view.capturing=true;}
        const nativeState=JSON.parse(micNative.status()) as CaptureReply;if(nativeState.error||!nativeState.running){throw new Error('microphone_capture_stopped_or_interrupted');}
        // At most eight packets per tick: a slow bridge cannot create an unbounded queue.
        for(let index=0;index<8;index++){
          const packet=JSON.parse(micNative.read()) as CapturedPacket;if(packet.error){throw new Error('microphone_native_packet_error');}if(!packet.available){break;}
          if(packet.generation!==this.generation||packet.samples!==960||packet.base64.length>5336){throw new Error('microphone_invalid_native_packet');}
          if(!this.current(run)){return;}
          const reply=await this.command({action:'packet',generation:packet.generation,timestamp:packet.timestamp,base64:packet.base64});if(!this.current(run)){return;}if(reply.error||!reply.captureAllowed){throw new Error('microphone_send_stopped');}this.view.sentPackets=reply.sentPackets;
        }
        this.view.state='sending';this.view.text=`麦克风已开启 · 已提交 ${this.view.sentPackets} 个音频包；电脑实际应用录音待验证`;
      }
      this.emit();
    }catch(_){if(run===this.epoch){this.stopLocal();await this.command({action:'stop'}).catch(()=>undefined);this.view.state='error';this.view.text='麦克风已停止：授权、连接、远端确认或采集发生变化。重新开启需明确确认。';this.emit();}}
    finally{this.busy=false;}
  }
  async disable():Promise<void>{if(!this.intended&&this.generation===0&&!this.view.enabled&&this.view.state==='off'){return;}this.epoch++;this.stopLocal();this.view.state='off';this.view.text='麦克风已关闭';this.emit();await this.command({action:'stop'}).catch(()=>undefined);}
  async disconnect():Promise<void>{this.foreground=false;this.controlAllowed=false;await this.disable();}
  async dispose():Promise<void>{this.disposed=true;await this.disconnect();this.observer=undefined;this.context=undefined;}
}
