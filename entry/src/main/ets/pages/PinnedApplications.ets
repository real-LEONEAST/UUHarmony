import { preferences } from '@kit.ArkData';
import { UiColor } from './UiFoundation';
import { APP_STORE, PinnedApp, onAppsChanged, readPinnedApps } from './AppCatalog';

interface CatalogRoute {deviceKey:string;deviceName:string;}
@Component
export struct PinnedApplications {
  @Prop @Watch('load') deviceKey:string='';
  @Prop deviceName:string='';
  @Prop ready:boolean=false;
  launch:(id:string,name:string)=>void=()=>{};
  @State private apps:PinnedApp[]=[];
  private off:()=>void=()=>{};
  aboutToAppear():void {this.load();this.off=onAppsChanged(()=>this.load());}
  aboutToDisappear():void {this.off();}
  private load():void {
    try {this.apps=readPinnedApps(preferences.getPreferencesSync(this.getUIContext().getHostContext()!,{name:APP_STORE}),this.deviceKey);}
    catch(_) {this.apps=[];}
  }
  private open():void{
    if(!this.ready){return;}
    const route:CatalogRoute={deviceKey:this.deviceKey,deviceName:this.deviceName};
    this.getUIContext().getRouter().pushUrl({url:'pages/AppPicker',params:route}).catch(()=>{this.getUIContext().getPromptAction().showToast({message:'暂时无法打开应用列表'});});
  }
  build(){
    Column({space:8}){
      Row(){
        Text('快速启动').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
        Button(this.apps.length?'编辑':'添加应用').height(44).enabled(this.ready).backgroundColor(Color.Transparent).fontColor(UiColor.primary).onClick(()=>this.open())
      }.width('100%')
      Flex({wrap:FlexWrap.Wrap}){
        ForEach(this.apps,(app:PinnedApp)=>{
          Button(app.name).height(44).margin({right:6,bottom:4}).fontColor(UiColor.primary).backgroundColor(UiColor.primarySoft)
            .enabled(this.ready).onClick(()=>this.launch(app.id,app.name))
        },(app:PinnedApp)=>app.id)
      }
    }.width('100%').padding(14).borderRadius(16).backgroundColor(UiColor.surface)
  }
}
