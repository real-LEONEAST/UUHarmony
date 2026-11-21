export class PcTitleLayout {compact:boolean=false;showName:boolean=false;dragWidth:number=24;tabsWidth:number=48;}
export function pcTitleLayout(windowWidth:number,buttonInset:number):PcTitleLayout {
  const usable=Math.max(0,windowWidth-Math.max(0,buttonInset)-16);
  const result=new PcTitleLayout();result.compact=usable<420;result.showName=usable>=520;
  result.dragWidth=usable>=700?100:usable>=480?64:24;
  // Controls, icon/name and all inter-item spacing; usable already excludes padding.
  const fixed=result.compact?76:176+(result.showName?124:0);
  result.tabsWidth=Math.max(0,Math.min(usable-fixed-result.dragWidth,usable>=700?360:240));
  return result;
}
