import { virtualLibraryLifecycle } from './VirtualLibraryLifecycle';
import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { client, AuthView } from './AuthClient';
import { UiColor } from './UiFoundation';
import { OfficialKeyLibrary, LibraryRow } from './OfficialKeyLibrary';
import { VirtualPlan, VirtualControl } from './VirtualKeyModel';
import { adaptUuPlan, isBoundedVirtualJson } from './UuPlanAdapter';
import { publicVirtualPlan } from './PublicVirtualPlan';
import { validateVirtualPlan } from './VirtualPlanValidation';
import { VirtualPlanStore, StoredVirtualPlan } from './VirtualPlanStore';
import { VirtualPlanEditor } from './VirtualPlanEditor';
import { virtualSelection } from './VirtualPlanSelection';
import { formatVirtualBinding, parseVirtualBinding } from './VirtualKeyLabels';
import { virtualIssueText } from './VirtualIssueText';
import { layoutVirtualControls, VirtualPlacement, VirtualPlacementRequest, VirtualLayout } from './VirtualKeyLayout';
interface VirtualPlanRoute { origin?:string; mode?:string; }

@Entry
@Component
struct VirtualPlanPage {
 @State private tab:string='mine'; @State private message:string='选择或导入操控方案'; @State private search:string='';
 @State private local:StoredVirtualPlan[]=[]; @State private official:LibraryRow[]=[]; @State private busy:boolean=false;
 @State private controls:VirtualControl[]=[]; @State private selected:string=''; @State private planName:string='';
 @State private inspectId:string='';@State private moreId:string='';@State private selectedId:string='';@State private showAdd:boolean=false;@State private showDraft:boolean=false;@State private showCreate:boolean=false;
 private remoteOrigin:boolean=false;
 @State private leavingEditor:boolean=false; @State private editFolder:string=''; @State private selectedX:number=0.5; @State private selectedY:number=0.5;
 @State private itemName:string=''; @State private binding:string=''; @State private radius:number=25; @State private controlOpacity:number=0.8;
 @State private showCamera:boolean=false;@State private cameraOn:boolean=false;@State private cameraX:number=1;@State private cameraY:number=1;
 @State private canvasW:number=300; @State private canvasH:number=220;
 @State private pageW:number=0; @State private pageH:number=0;
 @StorageLink('uuSafeTop') private safeTop:number=12;
 @StorageLink('uuSafeBottom') private safeBottom:number=12;
 private context:common.UIAbilityContext|undefined=undefined;private store:VirtualPlanStore|undefined=undefined;
 private library:OfficialKeyLibrary=new OfficialKeyLibrary(()=>this.account());private editor:VirtualPlanEditor|undefined=undefined;
 private editing:StoredVirtualPlan|undefined=undefined;private version:string='';private scopeValue:string='';private epoch:number=0;private off:()=>void=()=>{};private offLifecycle:()=>void=()=>{};
 private localSerial:number=0;
 private dragId:number=-1;private dragX:number=0;private dragY:number=0;private dragStartX:number=0;private dragStartY:number=0;
 private account():string {return client.view.loggedIn&&!client.view.suspended?(client.view.wallpaperAccountKey||''):'';}
 private scope():string {return client.view.loggedIn?(client.view.wallpaperAccountKey||'unavailable'):'offline';}
 aboutToAppear():void{
  this.offLifecycle=virtualLibraryLifecycle.register(()=>this.cancelLibrary());
  this.context=this.getUIContext().getHostContext() as common.UIAbilityContext;
  this.off=client.monitor((_view:AuthView)=>{const scope=this.scope();if(scope!==this.scopeValue){this.epoch++;this.library.cancel();this.scopeValue=scope;virtualSelection.setScope(scope);this.local=[];this.store=undefined;if(scope==='unavailable'){this.message='登录资料尚未就绪，请稍候';}else if(this.context){this.store=new VirtualPlanStore(this.context,scope,()=>this.scope());}this.official=[];this.editor=undefined;this.editing=undefined;this.tab='mine';this.refresh();}});
  const route=this.getUIContext().getRouter().getParams() as VirtualPlanRoute;this.remoteOrigin=route?.origin==='remote';if(route?.mode==='edit'){this.editCurrent();}
 }
 private cancelLibrary():void{this.epoch++;this.library.cancel();this.busy=false;}
 onPageHide():void{this.cancelLibrary();}
 aboutToDisappear():void{this.cancelLibrary();this.offLifecycle();this.off();}
 private async refresh():Promise<void>{const run=this.epoch;const store=this.store;const rows=store?await store.list():[];const current=store?await store.current():undefined;if(run===this.epoch){this.local=rows;this.selectedId=current?.state==='ready'&&current.item?current.item.id:'';}}
 private async rawDefault():Promise<string>{if(!this.context){return '';}const data=await this.context.resourceManager.getRawFileContent('virtual-key-default.json');return util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(data);}
 private async addRaw(raw:string,source:string,version:string=''):Promise<void>{
  const run=this.epoch;if(!isBoundedVirtualJson(raw)){this.message='方案文件过大或嵌套过深';return;}let plan:VirtualPlan|undefined=undefined;
  try{const candidate=JSON.parse(raw) as VirtualPlan;plan=publicVirtualPlan(candidate);}catch(_){}
  if(plan&&source==='import'){plan.source='import';}
  if(!plan){const adapted=adaptUuPlan(raw,source);if(!adapted.ok||!adapted.plan){this.message='方案格式无效或超过限制：'+adapted.error;return;}plan=adapted.plan;}
  if(run!==this.epoch||!this.store){return;}const item=await this.store.create(raw,plan,version);if(run!==this.epoch){return;}
  this.message=item?'已加入我的方案':'保存未完成';await this.refresh();
 }
 private async editCurrent():Promise<void>{
  const store=this.store,run=this.epoch;if(!store){this.message='登录资料尚未就绪';return;}
  try{const current=await store.current();if(run!==this.epoch){return;}if(current.state==='ready'&&current.item){this.edit(current.item);return;}if(current.state==='invalid'){this.message='已选方案无法读取，请重新选择';return;}
   const raw=await this.rawDefault();const adapted=adaptUuPlan(raw,'builtin');if(run!==this.epoch||!adapted.ok||!adapted.plan){this.message='默认方案不可用';return;}
   const item=await store.create(raw,adapted.plan,'android-4.45.0');if(run!==this.epoch||!item){this.message='无法创建本地副本';return;}
   if(!await store.select(item.id)||run!==this.epoch){this.message='无法选择本地副本';return;}virtualSelection.set(item.plan,item.id);this.selectedId=item.id;this.edit(item);
  }catch(_){if(run===this.epoch){this.message='无法打开当前方案';}}
 }
 private async newPlan():Promise<void>{
  if(this.busy||!this.store){return;}const plan:VirtualPlan={formatVersion:1,name:'新方案',source:'local',coordinateSpace:'global',controls:[],issues:[],canActivate:true};
  const run=this.epoch;const item=await this.store.create(JSON.stringify(plan),plan);if(run!==this.epoch){return;}if(item){await this.refresh();this.edit(item);}else{this.message='新建未完成';}
 }
 private async builtin():Promise<void>{if(this.busy){return;}this.busy=true;try{await this.addRaw(await this.rawDefault(),'builtin','android-4.45.0');}catch(_){this.message='默认方案不可用';}finally{this.busy=false;}}
 private async listOfficial():Promise<void>{if(this.busy){return;}this.busy=true;const run=this.epoch;try{const result=await this.library.fetchDirectory();if(run===this.epoch){this.official=result.rows;this.version=result.version;this.message=result.message;}}finally{if(run===this.epoch){this.busy=false;}}}
 private async download(row:LibraryRow):Promise<void>{if(this.busy){return;}this.busy=true;const run=this.epoch;try{const result=await this.library.download(row.index);if(run!==this.epoch){return;}if(!result.ok){this.message=result.message;return;}await this.addRaw(result.raw,'official',this.version);}finally{if(run===this.epoch){this.busy=false;}}}
 private async importFile():Promise<void>{if(this.busy||!this.context){return;}this.busy=true;const run=this.epoch;let file:fileIo.File|undefined=undefined;
  try{const options=new picker.DocumentSelectOptions();options.maxSelectNumber=1;options.selectMode=picker.DocumentSelectMode.FILE;const uris=await new picker.DocumentViewPicker(this.context).select(options);if(run!==this.epoch||uris.length!==1||!uris[0].startsWith('file://')){return;}file=await fileIo.open(uris[0],fileIo.OpenMode.READ_ONLY);const st=await fileIo.stat(file.fd);if(!st.isFile()||st.size<1||st.size>1048576){this.message='文件超过限制';return;}const bytes=new Uint8Array(st.size);let offset=0;while(offset<bytes.length){const part=new ArrayBuffer(bytes.length-offset);const n=await fileIo.read(file.fd,part,{length:part.byteLength});if(n<1||n>part.byteLength){throw Error('read');}bytes.set(new Uint8Array(part,0,n),offset);offset+=n;}if(run===this.epoch){await this.addRaw(util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(bytes),'import');}}
  catch(_){if(run===this.epoch){this.message='导入未完成';}}finally{if(file){await fileIo.close(file).catch(()=>{});}if(run===this.epoch){this.busy=false;}}
 }
 private async exportFile(item:StoredVirtualPlan):Promise<void>{if(this.busy||!this.context||!validateVirtualPlan(item.plan)){return;}this.busy=true;const run=this.epoch;let file:fileIo.File|undefined=undefined;
  try{const options=new picker.DocumentSaveOptions();options.newFileNames=['UUHarmony-操控方案.json'];const uris=await new picker.DocumentViewPicker(this.context).save(options);if(run!==this.epoch||uris.length!==1||!uris[0].startsWith('file://')){return;}const clean=publicVirtualPlan(item.plan);if(!clean){this.message='方案不能导出';return;}const data=new util.TextEncoder().encodeInto(JSON.stringify(clean));file=await fileIo.open(uris[0],fileIo.OpenMode.WRITE_ONLY|fileIo.OpenMode.CREATE|fileIo.OpenMode.TRUNC);let offset=0;while(offset<data.length){const part=data.slice(offset);const n=await fileIo.write(file.fd,part.buffer,{length:part.byteLength});if(n<=0||n>part.length){throw Error('write');}offset+=n;}await fileIo.fsync(file.fd);this.message='已导出当前编辑结果';}catch(_){if(run===this.epoch){this.message='导出未完成';}}finally{if(file){await fileIo.close(file).catch(()=>{});}if(run===this.epoch){this.busy=false;}}
 }
 private sourceLabel(value:string):string{return value==='builtin'?'官方默认':value==='official'?'官方方案':value==='local'?'本机创建':'导入文件';}
 private confirmSelection(item:StoredVirtualPlan):void {
  const unavailable=item.plan.controls.filter((control:VirtualControl)=>!control.enabled);
  if(!unavailable.length&&!item.plan.camera?.enabled){this.choose(item);return;}
  const names=unavailable.map((control:VirtualControl):string=>(control.name||'未命名按键').slice(0,40)).join('、');
  const camera=item.plan.camera?.enabled?'此方案使用手动相对视角：拖动画面转动视角，不自动判断游戏锁鼠状态。':'';
  const disabled=names?'以下按键暂不可用：'+names+'。':'';
  AlertDialog.show({title:'确认操控方案',message:camera+disabled+'是否使用此方案？',primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'继续使用',action:()=>{this.choose(item);}}});
 }
 private async choose(item:StoredVirtualPlan):Promise<void>{
  if(this.busy||!this.store||!item.plan.canActivate){return;}this.busy=true;const run=this.epoch;
  try{const ok=await this.store.select(item.id);if(run!==this.epoch){return;}if(ok&&virtualSelection.set(item.plan,item.id)){this.selectedId=item.id;this.message='已选择 '+item.name;if(this.remoteOrigin){this.getUIContext().getRouter().back();}} else{this.message='选择未保存';}}
  finally{if(run===this.epoch){this.busy=false;}}
 }
 private edit(item:StoredVirtualPlan):void{try{this.editing=item;this.editor=new VirtualPlanEditor(item.plan);this.selected='';this.editFolder='';this.moreId='';this.showCreate=false;this.tab='edit';this.syncEditor();}catch(_){this.message='方案不能编辑';}}
 private syncEditor():void{if(!this.editor){return;}const plan=this.editor.snapshot();this.controls=plan.controls;this.planName=plan.name;this.cameraOn=plan.camera?.enabled||false;this.cameraX=plan.camera?.sensitivityX||1;this.cameraY=plan.camera?.sensitivityY||1;if(this.selected&&!this.controls.some((c:VirtualControl)=>c.id===this.selected)){this.selected='';}}
 private selectControl(c:VirtualControl):void{this.selected=c.id;this.itemName=c.name;this.binding=formatVirtualBinding(c.actions);this.selectedX=c.x;this.selectedY=c.y;if(c.kind==='folder_list'||c.kind==='folder_round'){this.editFolder=c.id;}this.radius=c.radius;this.controlOpacity=c.opacity;}
 private applyCamera():void{if(!this.editor){return;}this.message=this.editor.camera(this.cameraOn,this.cameraX,this.cameraY)?'视角设置已更新':'视角设置无效';this.syncEditor();}
 private applyControl():void{if(!this.editor){return;}const c=this.controls.find((v:VirtualControl)=>v.id===this.selected);if(!c){return;}const actions=(c.kind==='key'||c.kind==='mouse'||c.kind==='combo')?parseVirtualBinding(this.binding):c.actions;this.message=this.editor.update(c.id,this.selectedX,this.selectedY,this.radius,this.controlOpacity,this.itemName,actions)?'草稿已更新':'绑定或属性无效';this.syncEditor();}
 private addControl(kind:string):void{if(!this.editor){return;}if(this.editFolder&&(kind==='folder_list'||kind==='folder_round')){this.message='功能夹内不能再添加功能夹';return;}const now=Date.now().toString(36)+'-'+(++this.localSerial).toString(36);const siblings=this.controls.filter((item:VirtualControl)=>item.ownerId===this.editFolder);let order=0;while(siblings.some((item:VirtualControl)=>item.order===order)&&order<128){order++;}if(order>=128){this.message='功能夹已满';return;}const c:VirtualControl={id:'local-'+now,kind:kind==='combo'?'combo':kind==='mouse'?'mouse':kind==='direction'?'direction':kind==='wheel'?'wheel':kind==='folder_list'?'folder_list':kind==='folder_round'?'folder_round':'key',label:'',name:kind==='mouse'?'鼠标左键':kind==='direction'?'方向轮盘':kind==='combo'?'组合键':kind==='wheel'?'滚轮':kind==='folder_list'?'列表功能夹':kind==='folder_round'?'轮盘功能夹':'按键',x:0.5,y:0.5,radius:28,opacity:0.8,visible:true,draggable:kind==='mouse',ownerId:this.editFolder,order:order,actions:kind==='combo'?['k:162','k:65']:kind==='mouse'?['m:1']:kind==='direction'?['k:87','k:65','k:83','k:68']:kind==='wheel'||kind==='folder_list'||kind==='folder_round'?[]:['k:65'],enabled:true,issues:[]};if(this.editor.add(c)){this.syncEditor();this.selectControl(c);}else{this.message='无法添加控件';}}
 onBackPress():boolean{if(this.leavingEditor){this.leavingEditor=false;return true;}if(this.tab==='edit'){this.moreId='';this.showCreate=false;this.leavingEditor=true;return true;}if(this.moreId){this.moreId='';return true;}if(this.showCreate){this.showCreate=false;return true;}return false;}
 private discardEditor():void{this.leavingEditor=false;this.tab='mine';this.editor=undefined;this.editing=undefined;this.editFolder='';}
 private async saveDraft():Promise<void>{if(!this.editor||!this.editing||!this.store){return;}this.message=await this.store.saveDraft(this.editing,this.editor.snapshot())?'草稿已保存':'草稿未保存';}
 private async loadDraft():Promise<void>{if(!this.editing||!this.store){return;}const plan=await this.store.loadDraft(this.editing);if(plan){this.editor=new VirtualPlanEditor(plan);this.syncEditor();this.message='已载入保存的草稿';}else{this.message='没有可用草稿';}}
 private async saveEditor():Promise<void>{if(!this.editor||!this.editing||!this.store){return;}const plan=this.editor.snapshot();const run=this.epoch;const ok=await this.store.save(this.editing,plan);if(run!==this.epoch){return;}this.message=ok?'已保存方案':'保存失败，草稿仍保留';if(ok){if(virtualSelection.matches(this.editing.id)){virtualSelection.set(plan,this.editing.id);}this.leavingEditor=false;this.tab='mine';this.editor=undefined;this.editing=undefined;this.editFolder='';await this.refresh();}}
 private previewKey:string='';private previewCache:VirtualLayout={complete:false,items:[]};
 private preview():VirtualLayout{
  const roots=this.controls.filter((control:VirtualControl)=>!control.ownerId);const key=JSON.stringify([this.canvasW,this.canvasH,roots]);
  if(key!==this.previewKey){const digits=roots.filter((control:VirtualControl)=>['1','2','3','4'].includes(control.label));const align=!!this.editor&&this.editor.snapshot().source==='builtin'&&digits.length===4&&digits.every((control:VirtualControl)=>Math.abs(control.x-digits[0].x)<0.002&&Math.abs(control.radius-digits[0].radius)<0.1);const requests:VirtualPlacementRequest[]=roots.map((control:VirtualControl):VirtualPlacementRequest=>({id:control.id,x:control.x*this.canvasW,y:control.y*this.canvasH,size:Math.max(40,Math.min(160,control.radius*2)),group:align&&digits.includes(control)?'builtin-digits':''}));this.previewCache=layoutVirtualControls(requests,this.canvasW,this.canvasH);this.previewKey=key;}return this.previewCache;
 }
 private previewPosition(c:VirtualControl):VirtualPlacement{return this.preview().items.find((item:VirtualPlacement)=>item.id===c.id)||{id:c.id,x:0,y:0,size:32};}
 private controlTouch(c:VirtualControl,e:TouchEvent):void{
  e.stopPropagation();if(!this.editor){return;}if(e.type===TouchType.Down&&e.changedTouches.length){const t=e.changedTouches[0];this.dragId=t.id;this.dragX=t.windowX;this.dragY=t.windowY;this.dragStartX=c.x;this.dragStartY=c.y;this.selectControl(c);}
  else if(e.type===TouchType.Up&&e.changedTouches.some((t:TouchObject)=>t.id===this.dragId)){const t=e.changedTouches.find((v:TouchObject)=>v.id===this.dragId);if(t){const x=Math.max(0,Math.min(1,this.dragStartX+(t.windowX-this.dragX)/this.canvasW));const y=Math.max(0,Math.min(1,this.dragStartY+(t.windowY-this.dragY)/this.canvasH));this.editor.update(c.id,x,y,c.radius,c.opacity,c.name,c.actions);this.selectedX=x;this.selectedY=y;this.syncEditor();}this.dragId=-1;}
  else if(e.type===TouchType.Cancel){this.dragId=-1;}
 }
 @Builder
 private header(){
  Row({space:8}){
   Button('‹',{type:ButtonType.Normal}).id('virtualPlanBack').width(42).height(42).fontSize(26).padding(0).backgroundColor(UiColor.surface).fontColor(UiColor.text).onClick(()=>{if(!this.onBackPress()){this.getUIContext().getRouter().back();}})
   if(this.tab==='edit'&&this.pageW>0&&this.pageW<=this.pageH){
    Text('按键编辑').fontSize(19).fontColor(UiColor.text).fontWeight(FontWeight.Bold).layoutWeight(1)
    Button('保存').id('virtualEditSave').width(58).height(36).padding(0).fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary).onClick(()=>this.saveEditor())
   }else if(this.tab==='edit'){
    Text('按键编辑').fontSize(19).fontColor(UiColor.text).fontWeight(FontWeight.Bold)
    TextInput({text:this.planName,placeholder:'方案名称'}).id('virtualPlanName').width(120).height(36).fontSize(13).onChange((value:string)=>{this.planName=value;this.editor?.rename(value);})
    Blank().layoutWeight(1)
    Button('↶').id('virtualEditUndo').width(38).height(36).padding(0).onClick(()=>{this.editor?.undo();this.syncEditor();})
    Button('↷').id('virtualEditRedo').width(38).height(36).padding(0).onClick(()=>{this.editor?.redo();this.syncEditor();})
    Button('草稿').width(56).height(36).padding(0).onClick(()=>{this.showDraft=!this.showDraft;})
    Button('保存').id('virtualEditSave').width(58).height(36).padding(0).fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary).onClick(()=>this.saveEditor())
   }else{
    Text('操控方案').fontSize(20).fontColor(UiColor.text).fontWeight(FontWeight.Bold).layoutWeight(1)
    Button('＋').id('virtualCreateMenu').width(42).height(42).padding(0).fontSize(22).backgroundColor(UiColor.surface).fontColor(UiColor.text).onClick(()=>{this.showCreate=!this.showCreate;})
   }
  }.width('100%').height(48).constraintSize({minHeight:48,maxHeight:48}).flexShrink(0)
 }
 @Builder
 private previewControl(control:VirtualControl){
  Stack({alignContent:Alignment.Center}){
   if(control.kind==='direction'){
    Text('W').fontSize(10).fontColor(Color.White).position({left:this.previewPosition(control).size/2-4,top:3})
    Text('A').fontSize(10).fontColor(Color.White).position({left:4,top:this.previewPosition(control).size/2-6})
    Text('S').fontSize(10).fontColor(Color.White).position({left:this.previewPosition(control).size/2-4,top:this.previewPosition(control).size-16})
    Text('D').fontSize(10).fontColor(Color.White).position({left:this.previewPosition(control).size-13,top:this.previewPosition(control).size/2-6})
    Text('•').fontSize(12).fontColor(Color.White)
   }else{Text(control.name||control.label).fontSize(11).fontColor(Color.White).maxLines(2).textAlign(TextAlign.Center)}
  }.width(this.previewPosition(control).size).height(this.previewPosition(control).size).backgroundColor(control.id===this.selected?'#994A8DF4':'#775A6D85').border({width:control.id===this.selected?2:1,color:control.id===this.selected?'#FFFFFFFF':'#AADDDEEE'}).borderRadius(this.previewPosition(control).size/2).position({left:this.previewPosition(control).x,top:this.previewPosition(control).y}).id('virtualEditControl-'+control.id).onTouch((event:TouchEvent)=>this.controlTouch(control,event))
 }
 @Builder
 private addPalette(){
  Scroll(){Row({space:5}){
   Button('单键').onClick(()=>{this.addControl('key');this.showAdd=false;})
   Button('组合键').onClick(()=>{this.addControl('combo');this.showAdd=false;})
   Button('方向盘').onClick(()=>{this.addControl('direction');this.showAdd=false;})
   Button('鼠标').onClick(()=>{this.addControl('mouse');this.showAdd=false;})
   Button('滚轮').onClick(()=>{this.addControl('wheel');this.showAdd=false;})
   Button('列表夹').onClick(()=>{this.addControl('folder_list');this.showAdd=false;})
   Button('轮盘夹').onClick(()=>{this.addControl('folder_round');this.showAdd=false;})
  }}.scrollable(ScrollDirection.Horizontal).height(44).width('100%').backgroundColor(UiColor.surface)
 }
 @Builder
 private editorCanvas(){
  Stack({alignContent:Alignment.TopStart}){
   if(this.preview().complete){ForEach(this.controls.filter((control:VirtualControl)=>!control.ownerId),(control:VirtualControl)=>{this.previewControl(control)},(control:VirtualControl)=>control.id)}
   else{Text('窗口太小，无法安全预览所有按键').fontSize(13).fontColor(Color.White).padding(10)}
   Button('＋').id('virtualAddControl').width(38).height(38).fontSize(22).padding(0).backgroundColor(UiColor.surface).fontColor(UiColor.text).position({right:8,top:8}).onClick(()=>{this.showAdd=!this.showAdd;})
   if(this.editFolder){
    Scroll(){Column({space:3}){
     Text('功能夹内容').fontSize(12).fontColor(UiColor.text)
     ForEach(this.controls.filter((control:VirtualControl)=>control.ownerId===this.editFolder),(child:VirtualControl)=>{Button(child.name).fontSize(12).height(32).onClick(()=>this.selectControl(child))},(child:VirtualControl)=>child.id)
     Button('返回').fontSize(12).height(32).onClick(()=>{this.editFolder='';})
    }.width('100%')}.width(140).height(Math.max(80,this.canvasH-16)).position({left:8,top:8}).backgroundColor(UiColor.surface).borderRadius(10)
   }
  }.id('virtualEditCanvas').width('100%').layoutWeight(1).backgroundColor('#304967').clip(true).onAreaChange((_old:Area,area:Area)=>{this.canvasW=Number(area.width);this.canvasH=Number(area.height);})
 }
 @Builder
 private editorProperties(){
  Scroll(){Row({space:6}){
   if(this.selected){
    Text('名称').fontSize(12).fontColor(UiColor.text)
    TextInput({text:this.itemName,placeholder:'显示名称'}).id('virtualControlName').width(96).height(36).fontSize(12).onChange((v:string)=>{this.itemName=v;})
    Text('大小').fontSize(12).fontColor(UiColor.text)
    Slider({value:this.radius,min:16,max:100,step:1}).width(95).onChange((v:number)=>{this.radius=v;})
    Text('透明度').fontSize(12).fontColor(UiColor.text)
    Slider({value:this.controlOpacity,min:0.1,max:1,step:0.05}).width(95).onChange((v:number)=>{this.controlOpacity=v;})
    if(this.controls.some((control:VirtualControl)=>control.id===this.selected&&['key','mouse','combo'].includes(control.kind))){
     Text('绑定').fontSize(12).fontColor(UiColor.text)
     TextInput({text:this.binding,placeholder:'Ctrl + A'}).id('virtualBinding').width(110).height(36).fontSize(12).onChange((v:string)=>{this.binding=v;})
    }
    Button('应用').id('virtualApplyControl').height(36).onClick(()=>this.applyControl())
    Button('复制').height(36).onClick(()=>{this.editor?.copy(this.selected);this.syncEditor();})
    Button('删除').id('virtualDeleteControl').height(36).onClick(()=>{this.editor?.remove(this.selected);this.selected='';this.syncEditor();})
    Text('位置').fontSize(12).fontColor(UiColor.text)
    Slider({value:this.selectedX,min:0,max:1,step:0.01}).width(90).onChange((v:number)=>{this.selectedX=v;})
    Slider({value:this.selectedY,min:0,max:1,step:0.01}).width(90).onChange((v:number)=>{this.selectedY=v;})
   }
   if(this.editor?.snapshot().camera){Button('视角').id('virtualCameraSettings').height(36).onClick(()=>{this.showCamera=!this.showCamera;})}
  }.height(48).padding({left:8,right:8})}.scrollable(ScrollDirection.Horizontal).width('100%').height(48).backgroundColor(UiColor.surface)
 }
 @Builder
 private cameraSettings(){
  Row({space:6}){
   Text('手动相对视角').fontSize(12).fontColor(UiColor.text)
   Toggle({type:ToggleType.Switch,isOn:this.cameraOn}).onChange((value:boolean)=>{this.cameraOn=value;})
   Text('横向').fontSize(12).fontColor(UiColor.text)
   Slider({value:this.cameraX,min:0.1,max:5,step:0.1}).width(100).onChange((value:number)=>{this.cameraX=value;})
   Text('纵向').fontSize(12).fontColor(UiColor.text)
   Slider({value:this.cameraY,min:0.1,max:5,step:0.1}).width(100).onChange((value:number)=>{this.cameraY=value;})
   Button('应用').height(36).onClick(()=>this.applyCamera())
  }.width('100%').height(44).padding({left:8,right:8}).backgroundColor(UiColor.surface)
 }
 @Builder
 private localRow(item:StoredVirtualPlan){
  Column({space:0}){
   Row({space:10}){
    Text(item.plan.source==='builtin'?'⌨':'▦').fontSize(20).fontColor(UiColor.onPrimary).textAlign(TextAlign.Center).width(42).height(42).backgroundColor(UiColor.primary).borderRadius(10)
    Column({space:2}){Text(item.name).fontSize(15).fontColor(UiColor.text).maxLines(1).width('100%');Text(this.sourceLabel(item.plan.source)+' · '+item.plan.controls.length+' 个按键').fontSize(11).fontColor(UiColor.secondary).width('100%')}.layoutWeight(1)
    Button('⋯').id('virtualMore-'+item.id).width(36).height(36).padding(0).backgroundColor(UiColor.surface).fontColor(UiColor.text).onClick(()=>{this.moreId=this.moreId===item.id?'':item.id;this.inspectId='';})
    Button(this.selectedId===item.id?'✓':'使用').id('virtualUse-'+item.id).height(36).fontSize(12).padding({left:9,right:9}).enabled(item.plan.canActivate).backgroundColor(this.selectedId===item.id?UiColor.primary:UiColor.primarySoft).fontColor(this.selectedId===item.id?UiColor.onPrimary:UiColor.primary).onClick(()=>this.confirmSelection(item))
   }.width('100%').height(62)
   if(this.moreId===item.id){
    Scroll(){Row({space:5}){
     Button('编辑').id('virtualEdit-'+item.id).onClick(()=>this.edit(item))
     Button('兼容报告').onClick(()=>{this.inspectId=this.inspectId===item.id?'':item.id;})
     Button('复制').id('virtualCopy-'+item.id).onClick(async()=>{if(!this.store){return;}const raw=await this.store.source(item);if(!raw){this.message='原文摘要校验失败';return;}const plan=JSON.parse(JSON.stringify(item.plan)) as VirtualPlan;plan.name=(plan.name+' 副本').slice(0,80);await this.store.create(raw,plan,item.sourceVersion);await this.refresh();})
     Button('导出').id('virtualExport-'+item.id).onClick(()=>this.exportFile(item))
    }}.scrollable(ScrollDirection.Horizontal).width('100%').height(44)
   }
   if(this.inspectId===item.id){
    Text(this.sourceLabel(item.plan.source)+(item.sourceVersion?' · '+item.sourceVersion:'')+'\n原文摘要 '+item.rawSha256).fontSize(11).fontColor(UiColor.secondary).width('100%')
    ForEach(item.plan.issues,(issue:string)=>{Text(virtualIssueText(issue)).fontSize(11).fontColor(UiColor.secondary).width('100%')},(issue:string)=>issue)
    ForEach(item.plan.controls.filter((control:VirtualControl)=>control.issues.length>0),(control:VirtualControl)=>{Text(control.name+'：'+control.issues.map((issue:string)=>virtualIssueText(issue)).join('、')).fontSize(11).fontColor(UiColor.secondary).width('100%')},(control:VirtualControl)=>control.id)
   }
  }.width('100%').padding({left:12,right:12}).backgroundColor(UiColor.surface).borderRadius(10)
 }
 @Builder
 private management(){
  Row(){
   Button('我的方案').id('virtualMineTab').layoutWeight(1).height(42).backgroundColor(this.tab==='mine'?UiColor.primarySoft:UiColor.background).fontColor(this.tab==='mine'?UiColor.primary:UiColor.text).onClick(()=>{this.tab='mine';this.search='';})
   Button('官方方案').id('virtualOfficialTab').layoutWeight(1).height(42).backgroundColor(this.tab==='official'?UiColor.primarySoft:UiColor.background).fontColor(this.tab==='official'?UiColor.primary:UiColor.text).onClick(()=>{this.tab='official';this.search='';})
  }.width('100%').height(42).constraintSize({minHeight:42,maxHeight:42}).flexShrink(0)
  Row({space:8}){
   TextInput({text:this.search,placeholder:'输入游戏或方案名称'}).id('virtualOfficialSearch').layoutWeight(1).height(40).fontSize(13).onChange((value:string)=>{this.search=value;})
   if(this.tab==='official'){Button('读取目录').id('virtualLoadCatalog').height(40).enabled(!this.busy&&this.scopeValue!=='unavailable').onClick(()=>this.listOfficial())}
  }.width('100%').height(40).constraintSize({minHeight:40,maxHeight:40}).flexShrink(0)
  if(this.showCreate){
   Scroll(){Row({space:5}){
    Button('新建方案').id('virtualNewPlan').enabled(!this.busy&&this.scopeValue!=='unavailable').onClick(()=>{this.showCreate=false;this.newPlan();})
    Button('加入官方默认').id('virtualAddDefault').enabled(!this.busy&&this.scopeValue!=='unavailable').onClick(()=>{this.showCreate=false;this.builtin();})
    Button('导入文件').id('virtualImport').enabled(!this.busy&&this.scopeValue!=='unavailable').onClick(()=>{this.showCreate=false;this.importFile();})
   }}.scrollable(ScrollDirection.Horizontal).height(46).width('100%')
  }
  Scroll(){Column({space:5}){
   if(this.tab==='mine'){
    if(!this.local.length){Text('还没有方案，点击右上角添加').fontSize(13).fontColor(UiColor.secondary).padding(16)}
    ForEach(this.local.filter((item:StoredVirtualPlan)=>item.name.toLowerCase().includes(this.search.toLowerCase())),(item:StoredVirtualPlan)=>{this.localRow(item)},(item:StoredVirtualPlan)=>item.id)
   }else{
    if(!this.official.length){Text('点击读取目录，按需获取官方方案').fontSize(13).fontColor(UiColor.secondary).padding(16)}
    ForEach(this.official.filter((row:LibraryRow)=>row.name.toLowerCase().includes(this.search.toLowerCase())),(row:LibraryRow)=>{
     Row({space:10}){Text('▦').fontSize(20).fontColor(UiColor.onPrimary).textAlign(TextAlign.Center).width(42).height(42).backgroundColor(UiColor.primary).borderRadius(10);Column({space:2}){Text(row.name).fontSize(15).fontColor(UiColor.text).width('100%');Text('官方方案').fontSize(11).fontColor(UiColor.secondary).width('100%')}.layoutWeight(1);Button('获取').id('virtualDownload-'+row.index).height(36).enabled(!this.busy).onClick(()=>this.download(row))}.width('100%').height(62).padding({left:12,right:12}).backgroundColor(UiColor.surface).borderRadius(10)
    },(row:LibraryRow)=>row.index.toString())
   }
  }.width('100%').justifyContent(FlexAlign.Start)}.layoutWeight(1).width('100%').align(Alignment.Top)
 }
 build(){
  Column({space:6}){
   this.header()
   if(this.leavingEditor){
    Column({space:8}){Text('保存对布局的修改？').fontSize(16).fontColor(UiColor.text);Row({space:8}){Button('保存').id('virtualExitSave').onClick(()=>this.saveEditor());Button('放弃').id('virtualExitDiscard').onClick(()=>this.discardEditor());Button('继续编辑').id('virtualExitContinue').onClick(()=>{this.leavingEditor=false;})}}.padding(12).backgroundColor(UiColor.surface).borderRadius(10)
   }else if(this.tab==='edit'&&this.pageW>0&&this.pageW<=this.pageH){
    Column(){Text('横屏后编辑按键布局').fontSize(16).fontColor(UiColor.secondary)}.id('virtualEditLandscapeHint').width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
   }else if(this.tab==='edit'){
    if(this.showDraft){Row({space:6}){Button('保存草稿').id('virtualDraftSave').onClick(()=>this.saveDraft());Button('载入草稿').id('virtualDraftLoad').onClick(()=>this.loadDraft())}.height(42).width('100%')}
    if(this.showAdd){this.addPalette()}
    this.editorCanvas()
    if(this.showCamera){this.cameraSettings()}
    this.editorProperties()
   }else{this.management()}
   if(this.message.length&&this.message!=='选择或导入操控方案'){Text(this.message).fontSize(11).fontColor(UiColor.secondary).maxLines(2).width('100%')}
  }.id('virtualPlanRoot').width('100%').height('100%').padding({left:12,right:12,top:this.safeTop+6,bottom:this.safeBottom+6}).backgroundColor(UiColor.background).justifyContent(FlexAlign.Start).expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM]).onAreaChange((_old:Area,area:Area)=>{this.pageW=Number(area.width);this.pageH=Number(area.height);if(this.pageW<=this.pageH){this.dragId=-1;}})
 }
}
