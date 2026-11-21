// SPDX-License-Identifier: GPL-3.0-only
import { CodexThread } from './CodexHistoryModel';
export interface CodexWorkspaceSummary {id:string;label:string;path:string;count:number;updatedAt:number;}
export function codexWorkspaceSummaries(threads:CodexThread[]):CodexWorkspaceSummary[]{
  const result:CodexWorkspaceSummary[]=[];
  for(const t of threads){
    let w=result.find((item:CodexWorkspaceSummary)=>item.id===t.workspace);
    if(!w){const parts=t.workspaceLabel.replace(/\\/g,'/').split('/').filter((x:string)=>x.length>0);w={id:t.workspace,label:parts[parts.length-1]||t.workspaceLabel||'未命名工作区',path:t.workspaceLabel,count:0,updatedAt:0};result.push(w);}
    w.count++;w.updatedAt=Math.max(w.updatedAt,t.updatedAt||0);
  }
  return result.sort((a:CodexWorkspaceSummary,b:CodexWorkspaceSummary)=>b.updatedAt-a.updatedAt||a.id.localeCompare(b.id));
}
export function codexRecentThreads(threads:CodexThread[],limit:number=6):CodexThread[]{
  return threads.slice().sort((a:CodexThread,b:CodexThread)=>b.updatedAt-a.updatedAt||a.id.localeCompare(b.id)).slice(0,Math.max(0,limit));
}
export function codexRole(type:string):string{return type==='userMessage'?'你':type==='agentMessage'?'Codex':type==='plan'?'计划':'工具 · '+type;}
