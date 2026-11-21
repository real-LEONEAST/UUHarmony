export interface PickerResumeIntent {pageEpoch:number;sessionEpoch:number;deviceKey:string;}
export interface PickerResumeState {pageEpoch:number;foreground:boolean;generation:number;lastFailure:string;busy:boolean;closing:boolean;selected:string;hasChoice:boolean;}
export function canResumePickerSession(intent:PickerResumeIntent,state:PickerResumeState):boolean{
  return state.hasChoice&&state.pageEpoch===intent.pageEpoch&&state.foreground&&!state.busy&&!state.closing&&state.generation===intent.sessionEpoch+1&&state.lastFailure==='application_background'&&(state.selected===''||state.selected===intent.deviceKey);
}
