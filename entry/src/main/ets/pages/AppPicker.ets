import { preferences } from '@kit.ArkData';
import { session } from './SessionClient';
import { APP_STORE, PinnedApp, readPinnedApps, saveApps, scanApps, readAppIcon, delay } from './AppCatalog';
import { UiColor } from './UiFoundation';
interface PickerRoute {deviceKey:string;deviceName:string;}
@Entry
@Component
struct AppPicker {
  @StorageLink('uuSafeTop') private safeTop:number=12;
  @StorageLink('uuSafeBottom') private safeBottom:number=12;
  @State private apps:PinnedApp[]=[];
  @State private checked:string[]=[];
  @State private search:string='';
  @State private message:string='正在连接电脑…';
  @State private loaded:boolean=false;
  @State private images:Map<string,string>=new Map();
  private alive:boolean=false;
  private generation:number=-1;
  private deviceKey:string='';
  private stored:PinnedApp[]=[];
  private loadingIcons:boolean=false;
  private pendingIcons:string[]=[];
  private attempted:Set<string>=new Set();
  private valid():boolean{return this.alive&&session.catalogOnly&&session.generation===this.generation&&session.selected===this.deviceKey;}
  aboutToAppear():void{this.alive=true;this.start();}
  aboutToDisappear():void{this.alive=false;if(session.catalogOnly&&session.generation===this.generation&&session.selected===this.deviceKey){session.cancel('user_disconnect');}}
  private async start():Promise<void>{
    const r=this.getUIContext().getRouter().getParams() as PickerRoute;
    if(!r||!r.deviceKey||r.deviceKey==='assistance'){this.message='请选择自己的电脑';return;}
    this.deviceKey=r.deviceKey;
    try{
      const store=preferences.getPreferencesSync(this.getUIContext().getHostContext()!,{name:APP_STORE});
      this.stored=readPinnedApps(store,this.deviceKey); this.checked=this.stored.map((a:PinnedApp)=>a.id);
      if(!await session.select(this.deviceKey,r.deviceName,()=>this.alive)||!this.alive){if(this.alive){this.message='电脑暂时不可连接';}return;}
      const joining=session.joinCatalogConfirmed(this.deviceKey);
      this.generation=session.generation;await joining;
      const end=Date.now()+30000;
      while(this.valid()&&!session.controlOpen&&session.busy&&Date.now()<end){await delay(200);}
      if(!this.valid()||!session.controlOpen){if(this.alive){this.message='未能连接电脑，请返回重试';}return;}
      this.message='正在读取应用…';
      const rows=await scanApps(()=>this.valid());
      if(!this.valid()){return;}
      this.apps=rows.sort((a:PinnedApp,b:PinnedApp)=>a.name.localeCompare(b.name));
      this.loaded=true;this.message=this.apps.length?'':'电脑没有返回可添加的应用';
    }catch(_){if(this.alive){this.message='未取得应用列表，请检查电脑连接后重试';}}
  }
  private async icon(id:string):Promise<void>{
    if(this.attempted.has(id)){return;}this.attempted.add(id);this.pendingIcons.push(id);
    if(this.loadingIcons){return;}this.loadingIcons=true;
    try{while(this.pendingIcons.length&&this.valid()){const next=this.pendingIcons.shift()!;const src=await readAppIcon(next,()=>this.valid());if(src&&this.valid()){const map=new Map(this.images);map.set(next,src);this.images=map;}}}
    finally{this.loadingIcons=false;}
  }
  private toggle(id:string):void{this.checked=this.checked.includes(id)?this.checked.filter((s:string)=>s!==id):[...this.checked,id];}
  private async save():Promise<void>{
    if(!this.loaded){return;}
    try{
      const selected=this.apps.filter((a:PinnedApp)=>this.checked.includes(a.id));
      await saveApps(preferences.getPreferencesSync(this.getUIContext().getHostContext()!,{name:APP_STORE}),this.deviceKey,selected);
      if(this.alive){this.getUIContext().getRouter().back();}
    }catch(_){this.message='保存失败，请重试';}
  }
  build(){
    Column({space:12}){
      Row(){Button('取消').fontColor(UiColor.primary).backgroundColor(UiColor.primarySoft).onClick(()=>this.getUIContext().getRouter().back());Text('添加应用').fontColor(UiColor.text).fontSize(20).fontWeight(FontWeight.Medium).textAlign(TextAlign.Center).layoutWeight(1);Button('完成').fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary).enabled(this.loaded).onClick(()=>this.save())}.width('100%')
      TextInput({text:this.search,placeholder:'查找应用'}).fontColor(UiColor.text).placeholderColor(UiColor.secondary).caretColor(UiColor.primary).backgroundColor(UiColor.surface).onChange((s:string)=>{this.search=s;})
      if(this.message){Text(this.message).fontColor(UiColor.secondary)}
      List(){ForEach(this.apps.filter((a:PinnedApp)=>a.name.toLowerCase().includes(this.search.toLowerCase())),(a:PinnedApp)=>{
        ListItem(){Row({space:12}){
          Checkbox().selectedColor(UiColor.primary).unselectedColor(UiColor.secondary).mark({strokeColor:UiColor.onPrimary}).select(this.checked.includes(a.id)).hitTestBehavior(HitTestMode.None)
          if(this.images.has(a.id)){Image(this.images.get(a.id)).width(32).height(32).objectFit(ImageFit.Contain)}else{Text(a.name.slice(0,1)).width(32).textAlign(TextAlign.Center).fontColor(UiColor.primary)}
          Text(a.name).fontColor(UiColor.text).fontSize(16).layoutWeight(1).maxLines(2)
        }.width('100%').constraintSize({minHeight:54}).padding(8).onClick(()=>this.toggle(a.id)).onVisibleAreaChange([0,0.5],(visible:boolean,ratio:number)=>{if(visible&&ratio>0){this.icon(a.id);}})}
      },(a:PinnedApp)=>a.id)}.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%').padding({left:16,right:16,top:this.safeTop+8,bottom:this.safeBottom+8}).backgroundColor(UiColor.background)
  }
}
