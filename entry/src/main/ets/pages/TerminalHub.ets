// SPDX-License-Identifier: GPL-3.0-only
import { client } from './AuthClient';
import { session } from './SessionClient';
import { deviceCards } from './DeviceListModel';
import { UiColor } from './UiFoundation';
interface TerminalHubRoute {deviceKey:string;deviceName:string;}
@Entry @Component
struct TerminalHub {
 @State private connectionBusy:boolean=false;
 private stopState:()=>void=()=>{};
 @State private name:string='终端';@State private status:string='';@State private busy:boolean=false;
 @StorageLink('uuSafeTop') private safeTop:number=12;@StorageLink('uuSafeBottom') private safeBottom:number=12;
 private device:string='';private account:string='';private visible:boolean=false;private run:number=0;
 aboutToAppear():void{const route=this.getUIContext().getRouter().getParams() as TerminalHubRoute;if(route){this.device=route.deviceKey;this.name=route.deviceName;}this.account=client.view.wallpaperAccountKey||'';this.stopState=session.monitorState((blocked:boolean)=>{this.connectionBusy=blocked;});}
 onPageShow():void{this.visible=true;this.busy=false;this.connectionBusy=session.busy||session.isClosing;}
 aboutToDisappear():void{this.stopState();}
 onPageHide():void{this.visible=false;this.run++;}
 private current(run:number):boolean{return this.visible&&this.run===run&&client.view.loggedIn&&(client.view.wallpaperAccountKey||'')===this.account;}
 private codex():void{this.ordinary('codex');}
 private async ordinary(agent:string='ordinary'):Promise<void>{
  if(!this.current(this.run)||this.busy||session.busy||session.isClosing){return;}this.busy=true;const run=this.run;
  try{await client.refreshDevices(true);if(!this.current(run)){return;}const card=deviceCards(client.view.devices,false).find((c)=>c.key===this.device&&!c.current&&c.connectable);if(!card){this.status='电脑不可连接，请刷新设备列表后重试。';return;}
   if(!await session.select(card.key,card.name,()=>this.current(run))||!this.current(run)){return;}await this.getUIContext().getRouter().pushUrl({url:'pages/Terminal',params:{deviceKey:card.key,confirmed:true,initialTool:'terminal',agent:agent}});
  }catch(_){if(this.current(run)){this.status='暂时无法打开普通终端。';}}finally{this.busy=false;}
 }
 build(){Column({space:16}){
  Row(){Button('返回').fontColor(UiColor.primary).backgroundColor(Color.Transparent).onClick(()=>this.getUIContext().getRouter().back());Text('终端').fontSize(25).fontWeight(FontWeight.Bold).fontColor(UiColor.text).layoutWeight(1)}.width('100%')
  Text(this.name).fontSize(16).fontColor(UiColor.secondary).width('100%')
  Button({type:ButtonType.Normal}){Column({space:8}){Text('普通终端').fontSize(19).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%');Text('连接官方 UU 终端；退出时可选择保留会话。').fontSize(13).fontColor(UiColor.secondary).width('100%')}.padding(20)}.id('terminalOrdinary').width('100%').height('auto').backgroundColor(UiColor.surface).borderRadius(16).enabled(!this.busy&&!this.connectionBusy).onClick(()=>this.ordinary())
  Button({type:ButtonType.Normal}){Column({space:8}){Text('Codex').fontSize(19).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%');Text('使用电脑已有 Codex CLI，直接操作其会话恢复、菜单与审批。').fontSize(13).fontColor(UiColor.secondary).width('100%')}.padding(20)}.id('terminalCodex').width('100%').height('auto').backgroundColor(UiColor.surface).borderRadius(16).enabled(!this.busy&&!this.connectionBusy).onClick(()=>this.codex())
  Blank();Text(this.status).fontSize(12).fontColor(UiColor.secondary).width('100%')
 }.width('100%').height('100%').padding({top:this.safeTop+10,bottom:this.safeBottom+12,left:18,right:18}).backgroundColor(UiColor.background).expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])}
}
