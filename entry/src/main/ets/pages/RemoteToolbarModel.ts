import { DisplayState, ScreenRow } from './DisplayModel';

// A gesture yields at most one request. IDs come only from the latest inventory.
export function toolbarStep(dx:number,dy:number):number {
  if(!Number.isFinite(dx)||!Number.isFinite(dy)||Math.abs(dy)<48||Math.abs(dy)<Math.abs(dx)*1.25){return 0;}
  return dy<0?1:-1;
}
export function adjacentScreen(state:DisplayState|undefined,step:number):number|undefined {
  if(!state||!state.inventoryReceived||!state.switchCommandSupported||state.displayPending||step===0){return undefined;}
  const ids:number[]=[];
  for(const screen of state.screens){if(Number.isInteger(screen.id)&&screen.id>=0&&!ids.includes(screen.id)){ids.push(screen.id);}}
  ids.sort((a:number,b:number)=>a-b);
  if(ids.length<2){return undefined;}
  // A failed switch must be resolved by explicit selection, rather than guessing
  // which desktop is on screen while input remains blocked.
  if(state.inputBlocked||state.displayError){return undefined;}
  const at=ids.findIndex((id:number)=>id===state.selectedScreen);
  if(at<0){return undefined;}
  return ids[(at+(step>0?1:-1)+ids.length)%ids.length];
}
export function toolbarScreenLabel(state:DisplayState|undefined):string {
  if(!state||!state.inventoryReceived){return '等待屏幕信息';}
  if(state.displayPending){return '正在切换屏幕';}
  if(state.displayError){return '切换未完成';}
  const ids=state.screens.map((s:ScreenRow)=>s.id).filter((id:number,at:number,all:number[])=>all.indexOf(id)===at).sort((a:number,b:number)=>a-b);
  const at=ids.findIndex((id:number)=>id===state.selectedScreen);
  return at<0?'当前屏幕未知':`屏幕 ${at+1}/${ids.length}`;
}
