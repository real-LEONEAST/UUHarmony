// Width breakpoints follow the local HarmonyOS multi-device guide. All units are vp.
export type RemoteSizeClass = 'compact' | 'medium' | 'wide';
export interface RemoteLayout {
  width:number;height:number;sizeClass:RemoteSizeClass;compactHeight:boolean;
  panelWidth:number;panelMaxHeight:number;toolbarHorizontal:boolean;
}
function dimension(value:number):number{return Number.isFinite(value)&&value>0?value:0;}
export function remoteLayout(widthVp:number,heightVp:number):RemoteLayout {
  const width=dimension(widthVp),height=dimension(heightVp);
  const sizeClass:RemoteSizeClass=width<600?'compact':width<840?'medium':'wide';
  const compactHeight=height<480;
  const gap=width<360?12:20;
  const nominalPanel=compactHeight?360:sizeClass==='compact'?360:sizeClass==='medium'?400:440;
  return {width:width,height:height,sizeClass:sizeClass,compactHeight:compactHeight,
    panelWidth:Math.min(Math.max(0,width-gap*2),nominalPanel),
    panelMaxHeight:Math.max(0,height-(compactHeight?12:20)*2),
    // The product uses the same right-side vertical controls on every window class.
    toolbarHorizontal:false};
}
