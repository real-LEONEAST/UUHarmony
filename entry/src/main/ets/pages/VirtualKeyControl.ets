import { VirtualControl } from './VirtualKeyModel';
import { VirtualKeyRuntime } from './VirtualKeyRuntime';
interface Point {x:number; y:number;}
@Component
export struct VirtualKeyControl {
 @Prop control:VirtualControl={id:'',kind:'unsupported',label:'',name:'',x:0,y:0,radius:24,opacity:0.7,visible:true,draggable:false,ownerId:'',order:0,actions:[],enabled:false,issues:[]};
 runtime:VirtualKeyRuntime|undefined=undefined;
 @Prop controlSize:number=48;
 @Prop highlight:boolean=false;
 @State private held:boolean=false;
 private points:Map<number,Point>=new Map();
 private touch(event:TouchEvent):void{
  event.stopPropagation();const runtime=this.runtime;if(!runtime){return;}
  const live:number[]=[];for(const point of event.touches){if(!(event.type===TouchType.Up&&event.changedTouches.some((changed:TouchObject)=>changed.id===point.id))){live.push(point.id);}}runtime.observeContacts(live);
  if(event.type===TouchType.Down){for(const point of event.changedTouches){if(this.points.has(point.id)){continue;}this.points.set(point.id,{x:point.windowX,y:point.windowY});if(runtime.down(point.id,this.control,point.y<this.controlSize/2?120:-120)){this.held=true;if(this.control.kind==='direction'){const dx=(point.x-this.controlSize/2)/(this.controlSize/2);const dy=(point.y-this.controlSize/2)/(this.controlSize/2);runtime.move(point.id,this.control,dx,dy);}}}}
  else if(event.type===TouchType.Move){for(const point of event.touches){const prior=this.points.get(point.id);if(!prior){continue;}const dx=(point.x-this.controlSize/2)/(this.controlSize/2);const dy=(point.y-this.controlSize/2)/(this.controlSize/2);runtime.move(point.id,this.control,dx,dy,point.windowX-prior.x,point.windowY-prior.y);prior.x=point.windowX;prior.y=point.windowY;}}
  else if(event.type===TouchType.Up){for(const point of event.changedTouches){if(this.points.has(point.id)){this.points.delete(point.id);runtime.up(point.id);}}this.held=this.points.size>0;}
  else if(event.type===TouchType.Cancel){this.points.forEach((_point:Point,id:number)=>runtime.up(id,false));this.points.clear();this.held=false;}
 }
 aboutToDisappear():void{if(this.points.size){this.runtime?.suspend();}this.points.clear();this.held=false;}
 build(){
  Stack({alignContent:Alignment.Center}){
   if(this.control.kind==='direction'){
    Text('W').fontSize(12).fontColor(Color.White).position({left:this.controlSize/2-5,top:4});Text('A').fontSize(12).fontColor(Color.White).position({left:5,top:this.controlSize/2-7});
    Text('S').fontSize(12).fontColor(Color.White).position({left:this.controlSize/2-5,top:this.controlSize-20});Text('D').fontSize(12).fontColor(Color.White).position({left:this.controlSize-15,top:this.controlSize/2-7});
    Text('●').fontSize(14).fontColor(this.held?'#FFFFFFFF':'#99FFFFFF');
   }else if(this.control.kind==='wheel'){Text('▲\n▼').fontSize(13).fontColor(Color.White).textAlign(TextAlign.Center)}
   else{Text(this.control.name||this.control.label).fontSize(12).fontColor(Color.White).maxLines(2).textAlign(TextAlign.Center)}
  }.width(this.controlSize).height(this.controlSize).borderRadius(this.controlSize/2).border({width:this.held||this.highlight?2:1,color:this.held||this.highlight?'#FFFFFFFF':'#BBFFFFFF'}).backgroundColor(this.control.enabled?'#AA353535':'#66444444').opacity(this.control.opacity).hitTestBehavior(HitTestMode.Block).onTouch((event:TouchEvent)=>this.touch(event))
 }
}
