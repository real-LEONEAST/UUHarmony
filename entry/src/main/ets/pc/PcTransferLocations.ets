import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo, fileShare, picker } from '@kit.CoreFileKit';
import { pcDownloadFolder } from './PcDownloads';

export interface TransferLocations {
  receive: string;
  source: string;
  gallery: boolean;
}

const FOLDER_AUTH = 'SystemCapability.FileManagement.AppFileService.FolderAuthorization';
function settings(context: common.UIAbilityContext): preferences.Preferences {
  return preferences.getPreferencesSync(context, {name: 'uu.pc.transfer_locations'});
}

export function transferLocations(context: common.UIAbilityContext): TransferLocations {
  const store = settings(context);
  return {
    receive: String(store.getSync('receive', '')),
    source: String(store.getSync('source', '')),
    gallery: store.getSync('gallery', true) === true
  };
}

export async function saveTransferLocation(context: common.UIAbilityContext, key: string, value: string | boolean): Promise<void> {
  const store = settings(context);
  store.putSync(key, value);
  await store.flush();
}

function policy(uri: string, write: boolean): fileShare.PolicyInfo {
  return {uri: uri, operationMode: write ? fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE :
    fileShare.OperationMode.READ_MODE};
}

export async function activateTransferFolder(uri: string, write: boolean): Promise<void> {
  if (uri.startsWith('file://') && canIUse(FOLDER_AUTH)) {
    await fileShare.activatePermission([policy(uri, write)]);
  }
}

export async function chooseTransferFolder(context: common.UIAbilityContext, write: boolean, remember: boolean): Promise<string> {
  const options = new picker.DocumentSelectOptions();
  options.selectMode = picker.DocumentSelectMode.FOLDER;
  options.maxSelectNumber = 1;
  const uris = await new picker.DocumentViewPicker(context).select(options);
  if (uris.length !== 1 || !uris[0].startsWith('file://')) { return ''; }
  const uri = uris[0];
  const directory = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
  try {
    if (!(await fileIo.stat(directory.fd)).isDirectory()) { throw new Error('folder_required'); }
    if (remember) {
      if (!canIUse(FOLDER_AUTH)) { throw new Error('folder_authorization_unavailable'); }
      await fileShare.persistPermission([policy(uri, write)]);
      await activateTransferFolder(uri, write);
    }
  } finally { await fileIo.close(directory); }
  return uri;
}

export async function configuredReceiveFolder(context: common.UIAbilityContext, request: boolean): Promise<string> {
  const receive = transferLocations(context).receive;
  if (!receive) { return pcDownloadFolder(context, request); }
  await activateTransferFolder(receive, true);
  return receive;
}

export function transferFolderLabel(path: string): string {
  if (!path.startsWith('file://')) { return path; }
  const start = path.indexOf('/', 7);
  if (start < 0) { return ''; }
  const encoded = path.slice(start);
  try { return decodeURIComponent(encoded); } catch (_) { return encoded; }
}

export function appendTransferPath(folder: string, leaf: string): string {
  return folder.replace(/\/+$/, '') + '/' + (folder.startsWith('file://') ? encodeURIComponent(leaf) : leaf);
}

export function resolveLocalTransferPath(text: string, roots: string[]): string {
  const typed = text.trim().replace(/\/+$/, '');
  const local = transferFolderLabel(typed);
  if (!local.startsWith('/') || local.includes('\\') || /[\u0000-\u001f\u007f]/.test(local) ||
      local.split('/').some((part: string) => part === '.' || part === '..')) { return ''; }
  for (const root of roots) {
    const label = transferFolderLabel(root).replace(/\/+$/, '');
    if (!label || (local !== label && !local.startsWith(label + '/'))) { continue; }
    let path = root;
    for (const part of local.slice(label.length).split('/').filter((value: string) => !!value)) {
      path = appendTransferPath(path, part);
    }
    return path;
  }
  return '';
}
