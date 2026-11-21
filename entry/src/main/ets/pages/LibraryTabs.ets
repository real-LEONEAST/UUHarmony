import { UiColor } from './UiFoundation';
@Component
export struct LibraryTabs {
  @Prop selected:string='devices';
  @Prop compact:boolean=false;
  @Prop vertical:boolean=false;
  @Prop assistanceAvailable:boolean=true;
  onSelect:(tab:string)=>void=()=>{};
  @Builder
  tab(label:string,value:string){
    Button(label,{type:ButtonType.Normal}).id('libraryTab_'+value).layoutWeight(1).height(this.compact?40:52).padding({left:4,right:4}).fontSize(this.compact?13:15)
      .fontColor(this.selected===value?UiColor.primary:UiColor.secondary)
      .backgroundColor(this.selected===value?UiColor.primarySoft:Color.Transparent).borderRadius(14)
      .enabled(value!=='assistance'||this.assistanceAvailable).onClick(()=>this.onSelect(value))
  }
  @Builder
  sideTab(label:string,value:string){
    Button(label,{type:ButtonType.Normal}).id('libraryTab_'+value).width('100%').height(44).padding({left:2,right:2}).fontSize(12)
      .fontColor(this.selected===value?UiColor.primary:UiColor.secondary)
      .backgroundColor(this.selected===value?UiColor.primarySoft:Color.Transparent).borderRadius(12)
      .enabled(value!=='assistance'||this.assistanceAvailable).onClick(()=>this.onSelect(value))
  }
  build(){
    if(this.vertical){
      Column({space:6}){
        this.sideTab('我的设备','devices')
        this.sideTab('远程协助','assistance')
        this.sideTab('我的','account')
      }.id('libraryTabs').width(72).height('100%')
    }else{
      Row({space:8}){
        this.tab('我的设备','devices')
        this.tab('远程协助','assistance')
        this.tab('我的','account')
      }.id('libraryTabs').width('100%').padding({top:this.compact?4:8})
    }
  }
}
