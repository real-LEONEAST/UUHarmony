export interface RemotePresentationInput {
  width:number;height:number;left:number;right:number;top:number;bottom:number;
  railWidth:number;railHeight:number;mobile:boolean;panel:boolean;frameWidth:number;frameHeight:number;railTop?:number;
  pcControlsRight?:number;
}
export interface RemotePresentation {
  x:number;y:number;width:number;height:number;panelX:number;panelY:number;panelWidth:number;panelHeight:number;
}
export const MOBILE_TEXT_DOCK_HEIGHT:number=52;
export interface RemoteVideoTransform { scale:number;x:number;y:number; }
function positive(v:number):number{return Number.isFinite(v)?Math.max(0,v):0;}

// The Surface keeps its layout size. Only its visible frame is fitted above the editor.
export function fitVideoAboveKeyboard(stageHeight:number,frameHeight:number,editorTop:number):RemoteVideoTransform {
  const stage=Math.max(1,positive(stageHeight));
  const height=Math.max(1,Math.min(stage,positive(editorTop)));
  return {scale:Math.min(1,height/Math.max(1,positive(frameHeight))),x:0,y:(height-stage)/2};
}
// Canvas uses real avoid areas only; UI padding never reduces the desktop image.
export function remotePresentation(v:RemotePresentationInput):RemotePresentation {
  const w=positive(v.width),h=positive(v.height),x=Math.min(w,positive(v.left)),y=Math.min(h,positive(v.top));
  const width=Math.max(1,w-x-positive(v.right)-positive(v.railWidth));
  const bottom=Math.min(h-positive(v.bottom)-positive(v.railHeight),v.railTop??h);
  const available=Math.max(1,bottom-y);
  if(!v.mobile){
    const margin=Math.min(8,(width-1)/2);
    const gap=Math.min(8,available-1);
    const panelWidth=Math.min(440,width-margin*2);
    const right=Math.min(Math.max(margin,positive(v.pcControlsRight??8)),width-margin-panelWidth);
    const panelHeight=Math.max(1,Math.min(600,available*0.72,available-gap));
    return {x:x,y:y,width:width,height:available,panelX:x+width-panelWidth-right,panelY:y+gap,panelWidth:panelWidth,panelHeight:panelHeight};
  }
  const portrait=h>w;
  let height=available,panelHeight=!portrait?available:Math.min(340,available*0.72);
  const panelWidth=Math.max(1,Math.min(portrait?width-16:360,width-16));
  let panelY=y+available-panelHeight;
  if(v.panel&&portrait){
    const ratio=positive(v.frameWidth)>0&&positive(v.frameHeight)>0?v.frameHeight/v.frameWidth:9/16;
    height=Math.max(1,Math.min(available*0.45,width*ratio));
    panelHeight=Math.max(1,Math.min(available*0.65,available-height-16));panelY=y+height+8;
    if(v.railTop!==undefined){panelHeight=Math.max(1,Math.min(panelHeight,v.railTop-8-panelY));}
  }
  return {x:x,y:y,width:width,height:height,panelX:portrait?x+8:x+width-panelWidth-8,panelY:panelY,panelWidth:panelWidth,panelHeight:panelHeight};
}

export interface RemoteRailPlacement { left:number; top:number; width:number; height:number; }
export function remoteRailPlacement(width:number,height:number,left:number,right:number,top:number,bottom:number,horizontal:boolean,compact:boolean):RemoteRailPlacement {
  const x=Math.max(0,left)+8, y=Math.max(0,top)+8;
  const availableWidth=Math.max(1,width-x-Math.max(0,right)-8);
  const availableHeight=Math.max(1,height-y-Math.max(0,bottom)-8);
  const railWidth=Math.min(availableWidth,horizontal?(compact?318:368):(compact?70:80));
  const railHeight=horizontal?Math.min(availableHeight,64):availableHeight;
  return {left:horizontal?x+(availableWidth-railWidth)/2:width-Math.max(0,right)-8-railWidth,top:horizontal?height-Math.max(0,bottom)-8-railHeight:y+(availableHeight-railHeight)/2,width:railWidth,height:railHeight};
}
