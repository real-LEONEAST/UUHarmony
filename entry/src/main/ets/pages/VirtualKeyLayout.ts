// SPDX-License-Identifier: GPL-3.0-only
export interface VirtualPlacementRequest {id:string; x:number; y:number; size:number; group?:string;}
export interface VirtualPlacement {id:string; x:number; y:number; size:number;}
export interface VirtualLayout {complete:boolean; items:VirtualPlacement[];}
function overlaps(a:VirtualPlacement,b:VirtualPlacement):boolean{return a.x<b.x+b.size+2&&a.x+a.size+2>b.x&&a.y<b.y+b.size+2&&a.y+a.size+2>b.y;}
// Preserve normalized anchor wherever possible. Shrink uniformly only if collisions require it.
export function layoutVirtualControls(requests:VirtualPlacementRequest[],width:number,height:number):VirtualLayout {
 if(!Number.isFinite(width)||!Number.isFinite(height)||width<=0||height<=0||width<=height||requests.length>128){return {complete:false,items:[]};}
 for(const scale of [1,0.85,0.7,0.55,0.4]){
  const result:VirtualPlacement[]=[];let failed=false;
  const listParent=requests.find((r:VirtualPlacementRequest)=>r.group==='folder-list-parent');
  const listChildren=requests.filter((r:VirtualPlacementRequest)=>r.group==='folder-list-child');
  if(listParent&&listChildren.length){
   const parentSize=Math.max(32,Math.min(160,listParent.size*scale,width,height));
   let slot=32;for(const child of listChildren){slot=Math.max(slot,Math.max(32,Math.min(160,child.size*scale,width,height)));}
   const columns=Math.min(2,listChildren.length),rows=Math.ceil(listChildren.length/columns),gridW=columns*slot+(columns-1)*2,gridH=rows*slot+(rows-1)*2;
   if(gridH>height||parentSize+2+gridW>width){continue;}
   const parentX=Math.max(0,Math.min(width-parentSize,listParent.x-parentSize/2)),parentY=Math.max(0,Math.min(height-parentSize,listParent.y-parentSize/2));
   const right=width-(parentX+parentSize+2),left=parentX-2;let gridX=0;
   if(right>=gridW&&(listParent.x<=width/2||left<gridW)){gridX=parentX+parentSize+2;}else if(left>=gridW){gridX=parentX-2-gridW;}else if(right>=gridW){gridX=parentX+parentSize+2;}else{continue;}
   const gridY=Math.max(0,Math.min(height-gridH,listParent.y-gridH/2));result.push({id:listParent.id,x:parentX,y:parentY,size:parentSize});
   listChildren.forEach((r:VirtualPlacementRequest,index:number)=>{const size=Math.max(32,Math.min(160,r.size*scale,width,height));const x=gridX+(index%columns)*(slot+2)+(slot-size)/2,y=gridY+Math.floor(index/columns)*(slot+2)+(slot-size)/2;result.push({id:r.id,x:x,y:y,size:size});});
  }
  const digits=requests.filter((r:VirtualPlacementRequest)=>r.group==='builtin-digits').sort((a:VirtualPlacementRequest,b:VirtualPlacementRequest)=>a.y-b.y);
  if(digits.length===4){
   const size=Math.max(32,Math.min(160,digits[0].size*scale,width,height));const gap=size+2;
   if(size+gap*3>height){continue;}
   const centerX=digits.reduce((sum:number,r:VirtualPlacementRequest)=>sum+r.x,0)/4;
   const centerY=digits.reduce((sum:number,r:VirtualPlacementRequest)=>sum+r.y,0)/4;
   const left=Math.max(0,Math.min(width-size,centerX-size/2));const top=Math.max(0,Math.min(height-size-gap*3,centerY-size/2-gap*1.5));
   digits.forEach((r:VirtualPlacementRequest,index:number)=>{result.push({id:r.id,x:left,y:top+index*gap,size:size});});
  }
  for(const r of requests){
   if(digits.length===4&&r.group==='builtin-digits'||listParent&&listChildren.length&&(r.group==='folder-list-parent'||r.group==='folder-list-child')){continue;}
   if(!r.id||!Number.isFinite(r.x)||!Number.isFinite(r.y)||!Number.isFinite(r.size)){return {complete:false,items:[]};}
   const size=Math.max(32,Math.min(160,r.size*scale,width,height));const maxX=width-size,maxY=height-size;
   const left=Math.max(0,Math.min(maxX,r.x-size/2)),top=Math.max(0,Math.min(maxY,r.y-size/2));
   let chosen:VirtualPlacement|undefined=undefined;const step=Math.max(12,Math.floor(size/3));let attempts=0;
   for(let ring=0;ring<=Math.ceil(Math.max(width,height)/step)&&!chosen&&attempts<2500;ring++){
    for(let gy=-ring;gy<=ring&&!chosen;gy++){for(let gx=-ring;gx<=ring&&!chosen;gx++){
     if(ring>0&&Math.abs(gx)!==ring&&Math.abs(gy)!==ring){continue;}attempts++;
     const candidate:VirtualPlacement={id:r.id,x:Math.max(0,Math.min(maxX,left+gx*step)),y:Math.max(0,Math.min(maxY,top+gy*step)),size:size};
     if(!result.some((other:VirtualPlacement)=>overlaps(candidate,other))){chosen=candidate;}
    }}
   }
   if(!chosen){failed=true;break;}result.push(chosen);
  }
  if(!failed){return {complete:true,items:result};}
 }
 return {complete:false,items:[]};
}
