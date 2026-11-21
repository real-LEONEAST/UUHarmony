export interface ScreenSize {width:number;height:number;logicalWidth?:number;logicalHeight?:number;}
export interface ScreenRow {id:number;name:string;primary:boolean;native:ScreenSize;initial?:ScreenSize|null;currentResolution?:ScreenSize|null;videoTrackIndex:number;}
export interface PrivacyState {supported:boolean;reportedMode?:string;actualState?:string;error?:string;blocker:string;}
export interface DisplayReportError {action:number|null;errorCode:number|null;typeValue:number|null;}
export interface CaptureConfigResponse {requestSeq:number|null;configFlag:number|null;errorCode:number|null;}
export interface DisplayState {
  screens:ScreenRow[];inventoryReceived:boolean;inventoryGeneration:number;
  currentReported?:number|null;captureReported?:number|null;selectedScreen?:number|null;requestedScreen?:number|null;
  switchCommandSupported:boolean;switchCommandSent:boolean;remoteSwitchConfirmed?:boolean|null;
  changeKind?:string|null;displayEpoch:number;displayPending:boolean;inputBlocked:boolean;
  reportError?:DisplayReportError|null;captureConfigResponse?:CaptureConfigResponse|null;
  videoFrameObserved:boolean;resolutionMatched:boolean;streamFrameCompatible?:boolean;streamWithinBudget?:boolean|null;streamFrameReceived?:boolean;displayError?:string|null;screenBlocker:string;privacy:PrivacyState;error?:string;
}
export function currentFrameReady(rendered:number,renderedEpoch:number|undefined,videoEpoch:number|undefined,displayEpoch:number,width:number,height:number,blocked:boolean):boolean {
  return rendered>0&&renderedEpoch!==undefined&&renderedEpoch===displayEpoch&&videoEpoch===displayEpoch&&width>0&&height>0&&!blocked;
}
export function activeScreen(state:DisplayState|undefined):ScreenRow|undefined {
  if(!state||state.selectedScreen===null||state.selectedScreen===undefined){return undefined;}
  return state.screens.find((s:ScreenRow)=>s.id===state.selectedScreen);
}
export function resolutionSize(source:ScreenSize,viewport:ScreenSize,choice:string):ScreenSize {
  let box:ScreenSize=viewport;
  const portrait=source.height>source.width;
  if(choice==='720p'){box=portrait?{width:720,height:1280}:{width:1280,height:720};}
  if(choice==='1080p'){box=portrait?{width:1080,height:1920}:{width:1920,height:1080};}
  const scale=Math.min(1,Math.max(2,box.width)/Math.max(2,source.width),Math.max(2,box.height)/Math.max(2,source.height));
  return {width:Math.max(2,Math.floor(source.width*scale/2)*2),height:Math.max(2,Math.floor(source.height*scale/2)*2)};
}
export function displayErrorText(code:string):string {
  if(code==='active_decoder_size_unsupported'){return '本机当前解码器不支持这个尺寸，请选择较低分辨率。';}
  if(code==='screen_initial_size_unknown'){return '电脑未报告连接时的屏幕尺寸，暂无法请求原生分辨率。';}
  if(code==='screen_report_required'||code==='screen_current_size_unknown'){return '等待电脑报告当前显示器信息。';}
  if(code==='screen_switch_report_or_frame_timeout'){return '切屏等待超时；可重新选择目标屏幕。远程输入暂已暂停。';}
  if(code==='resolution_not_observed'){return '尚未收到符合要求的新画面，可重试传输缩放。';}
  if(code==='screen_track_not_negotiated'){return '电脑返回了未协商的视频轨道，请重新选择屏幕或重连。';}
  if(code==='video_track_registration_rejected'){return '电脑拒绝了视频轨道注册，请重新选择屏幕或重连。';}
  if(code==='screen_removed'||code==='screen_not_in_inventory'){return '该显示器已不可用，请重新选择。';}
  if(code==='text_channel_not_open'){return '画面设置通道尚未就绪，请稍后重试。';}
  if(code==='display_send_incomplete'){return '请求未完成发送，请重试。';}
  if(code==='invalid_width'||code==='invalid_height'){return '屏幕尺寸不符合当前视频格式的偶数像素要求。';}
  return '设置未完成：'+code;
}
export function displayStatus(state:DisplayState|undefined):string {
  if(!state||!state.inventoryReceived){return '等待电脑报告显示器信息';}
  if(state.displayError){if(state.changeKind==='stream_scale'&&state.streamFrameReceived){return '已收到新画面，但方向、比例或请求确认不符；输入暂已暂停。';}return displayErrorText(state.displayError);}
  if(state.changeKind==='switch'){
    if(!state.switchCommandSent){return '正在发送切屏请求';}
    if(!state.remoteSwitchConfirmed){return '切屏请求已发送，等待电脑报告目标屏幕';}
    return state.videoFrameObserved?'目标屏幕的新画面已送显':'电脑已报告目标屏幕，等待新画面';
  }
  if(state.changeKind==='stream_scale'){
    if(!state.videoFrameObserved){return state.streamFrameReceived?'已收到新画面，正在确认方向、比例与请求':'正在等待目标显示器的新画面';}
    if(!state.streamFrameCompatible){return '已收到新画面，正在确认方向、比例与请求';}
    if(state.streamWithinBudget===false){return '画面已送显，实际传输尺寸未达到请求的缩放预算';}
    if(state.resolutionMatched){return '画面已送显，传输尺寸与请求一致';}
    return '画面已送显，实际传输尺寸与请求不同';
  }
  if(state.changeKind==='resolution'){
    if(state.resolutionMatched){return '已收到所选传输尺寸的新画面';}
    return state.videoFrameObserved?'新画面已到达，尺寸尚未达到所选值':'传输尺寸请求已发送，等待新画面';
  }
  return '已收到 '+state.screens.length+' 块显示器，可按名称选择';
}
