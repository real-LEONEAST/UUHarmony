import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { Environment, fileIo } from '@kit.CoreFileKit';

export async function pcDownloadFolder(context: common.UIAbilityContext, request: boolean): Promise<string> {
  const permission = 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY';
  const manager = abilityAccessCtrl.createAtManager();
  const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
  if (manager.checkAccessTokenSync(info.appInfo.accessTokenId, permission) !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
    if (!request) { return ''; }
    const result = await manager.requestPermissionsFromUser(context, [permission]);
    if (result.authResults[0] !== 0) { return ''; }
  }
  const downloads = Environment.getUserDownloadDir();
  if (!downloads.startsWith('/')) { return ''; }
  const path = downloads + '/UUHarmony';
  if (!(await fileIo.access(path).catch(() => false))) {
    try { await fileIo.mkdir(path); } catch (_) {
      if (!(await fileIo.access(path).catch(() => false))) { return ''; }
    }
  }
  return (await fileIo.lstat(path)).isDirectory() ? path : '';
}
