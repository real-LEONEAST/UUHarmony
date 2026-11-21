import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import filesNative from 'libuufiles.so';
import { activateTransferFolder, appendTransferPath } from './PcTransferLocations';

export interface TransferRecord {
  id: string;
  direction: string;
  name: string;
  size: number;
  time: number;
  state: string;
  root: string;
  branch: string[];
  fingerprint: string;
}

function storePath(context: common.UIAbilityContext): string { return context.filesDir + '/uu-transfer-history'; }
function validId(id: string): boolean { return /^[a-z0-9-]{1,100}$/.test(id); }
function validLeaf(leaf: string): boolean {
  return !!leaf && leaf !== '.' && leaf !== '..' && !/[\\/\u0000-\u001f\u007f]/.test(leaf);
}

export async function addTransferRecord(context: common.UIAbilityContext, direction: string, name: string,
  size: number, state: string, root: string = '', fingerprint: string = '', branch: string[] = []): Promise<void> {
  await writeTransferRecord(context, {
    id: 'ui-' + util.generateRandomUUID(), direction: direction, name: name, size: size,
    time: Date.now(), state: state, root: root, branch: branch, fingerprint: fingerprint
  });
}

async function writeTransferRecord(context:common.UIAbilityContext, record:TransferRecord):Promise<void>{
  const folder = storePath(context);
  if (!await fileIo.access(folder).catch(() => false)) {
    try { await fileIo.mkdir(folder); } catch (_) { if (!await fileIo.access(folder)) { throw new Error('history_folder'); } }
  }
  const temporary='.'+util.generateRandomUUID();
  const partial=folder+'/'+temporary;
  const directory = await fileIo.open(folder, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
  try {
    const fd = filesNative.createExclusive(directory.fd, temporary);
    try {
      const bytes = new util.TextEncoder().encodeInto(JSON.stringify(record));
      if (await fileIo.write(fd, bytes.buffer) !== bytes.byteLength) { throw new Error('history_short_write'); }
      await fileIo.fsync(fd);
    } finally { await fileIo.close(fd); }
    await fileIo.rename(partial, folder + '/' + record.id + '.json');
  } finally {
    await fileIo.close(directory).catch(() => {});
    await fileIo.unlink(partial).catch(() => {});
  }
}

let legacyMigration:Promise<void>|undefined=undefined;
export async function importLegacyHistory(context:common.UIAbilityContext):Promise<void>{
  if(legacyMigration){return legacyMigration;}
  const task=migrateLegacyHistory(context);
  legacyMigration=task;
  try {await task;} finally {if(legacyMigration===task){legacyMigration=undefined;}}
}

async function migrateLegacyHistory(context:common.UIAbilityContext):Promise<void>{
  const prefs=preferences.getPreferencesSync(context,{name:'uu.pc.transfer.history'});
  if(prefs.getSync('legacyImported',false)===true){return;}
  const base=context.filesDir+'/uu-received';
  if(await fileIo.access(base).catch(()=>false)){
    if(!(await fileIo.lstat(base)).isDirectory()){throw new Error('legacy_history_root');}
    await indexLegacyFolder(context,base,base,[]);
  }
  prefs.putSync('legacyImported',true);
  await prefs.flush();
}

async function indexLegacyFolder(context:common.UIAbilityContext,base:string,path:string,branch:string[]):Promise<void>{
  const directory=await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
  try {
    for(const name of await fileIo.listFile(path)){
      if(!validLeaf(name)||name.toLowerCase().startsWith('.uu-partial-')){continue;}
      const child=path+'/'+name;
      const stat=await fileIo.lstat(child);
      if(stat.isDirectory()&&branch.length<32){
        await indexLegacyFolder(context,base,child,[...branch,name]);continue;
      }
      if(!stat.isFile()){continue;}
      const fingerprint=filesNative.inspectReceived(directory.fd,name);
      if(!fingerprint){continue;}
      const md=cryptoFramework.createMd('SHA256');
      const key=new util.TextEncoder().encodeInto(JSON.stringify([...branch,name]));
      await md.update({data:key});
      let id='legacy-';
      for(const byte of (await md.digest()).data){id+=byte.toString(16).padStart(2,'0');}
      if(await fileIo.access(storePath(context)+'/'+id+'.json').catch(()=>false)){continue;}
      await writeTransferRecord(context,{id:id,direction:'receive',name:name,size:stat.size,
        time:stat.mtime*1000,state:'complete',root:base,branch:branch,fingerprint:fingerprint});
    }
  } finally {await fileIo.close(directory);}
}

export async function readTransferHistory(context: common.UIAbilityContext): Promise<TransferRecord[]> {
  const folder = storePath(context);
  if (!await fileIo.access(folder).catch(() => false)) { return []; }
  const names = await fileIo.listFile(folder);
  const rows: TransferRecord[] = [];
  for (const name of names) {
    const id = name.endsWith('.json') ? name.slice(0, -5) : '';
    if (!validId(id)) { continue; }
    try {
      const record = JSON.parse(await fileIo.readText(folder + '/' + name)) as TransferRecord;
      if (record.id === id && typeof record.name === 'string' && validLeaf(record.name) &&
        typeof record.root === 'string' && typeof record.fingerprint === 'string' &&
        Number.isSafeInteger(record.size) && Number.isSafeInteger(record.time) &&
        ['send', 'receive'].includes(record.direction) && ['complete', 'failed'].includes(record.state) &&
        Array.isArray(record.branch) && record.branch.length <= 32 && record.branch.every((item: string) => validLeaf(item))) {
        rows.push(record);
      }
    } catch (_) {}
  }
  return rows.sort((a: TransferRecord, b: TransferRecord) => b.time - a.time);
}

export function hasReceivedFile(record: TransferRecord): boolean {
  return record.direction === 'receive' && record.state === 'complete' &&
    (record.root.startsWith('/') || record.root.startsWith('file://')) && /^[0-9:]+$/.test(record.fingerprint);
}

export async function removeTransferRecord(context: common.UIAbilityContext, record: TransferRecord,
  removeFile: boolean): Promise<boolean> {
  if (!validId(record.id)) { return false; }
  try {
    if (removeFile && hasReceivedFile(record)) {
      await activateTransferFolder(record.root, true).catch(() => {});
      let path = record.root;
      for (const part of record.branch) {
        if (!validLeaf(part)) { return false; }
        path = appendTransferPath(path, part);
      }
      const directory = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      try { if (filesNative.removeReceived(directory.fd, record.name, record.fingerprint) !== 0) { return false; } }
      finally { await fileIo.close(directory); }
    }
    await fileIo.unlink(storePath(context) + '/' + record.id + '.json');
    return true;
  } catch (_) { return false; }
}
