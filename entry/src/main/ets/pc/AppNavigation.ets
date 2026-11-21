import { UiColor,UiFont } from '../pages/UiFoundation';
@Component
export struct AppNavigation {
  @Prop selected:string='devices';
  @Prop wide:boolean=false;
  onSelect:(page:string)=>void=()=>{};
  @Builder item(page:string,label:string) {
    Button({type:ButtonType.Normal}) {
      Text((this.selected===page?'●  ':'')+label).fontSize(UiFont.action).fontColor(this.selected===page?UiColor.primary:UiColor.secondary)
        .textAlign(TextAlign.Start).width('100%')
    }.id(page==='devices'?'navDevices':page==='share'?'navPcHost':page==='assistance'?'navAssistance':'navAccount').height('auto').constraintSize({minHeight:48})
      .padding(14).borderRadius(14).backgroundColor(this.selected===page?UiColor.primarySoft:Color.Transparent)
      .accessibilityText(label+(this.selected===page?'，当前页面':'')).onClick(()=>{if(this.selected!==page){this.onSelect(page);}})
  }
  build() {
    if(this.wide){
      Column({space:16}) {
        Text('UUHarmony').fontSize(22).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%').padding({bottom:4})
        Text('远程连接与本机共享').fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%').margin({bottom:16})
        this.item('devices','我的设备')
        this.item('share','共享此电脑')
        this.item('assistance','远程协助')
        this.item('account','我的')
      }.width(208).height('100%').alignItems(HorizontalAlign.Start).padding({right:16})
    }else{
      Row({space:4}) {Column(){this.item('devices','设备')}.layoutWeight(1);Column(){this.item('share','共享')}.layoutWeight(1);Column(){this.item('assistance','协助')}.layoutWeight(1);Column(){this.item('account','我的')}.layoutWeight(1)}.width('100%')
    }
  }
}
