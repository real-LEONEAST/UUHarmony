import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { pcHost } from '../pc/PcHostService';
import { client } from './AuthClient';
import { UiColor, UiFont, UiSpace } from './UiFoundation';

@Component
export struct PcDeviceCover {
  @Prop online: boolean = false;
  @State private preview: image.PixelMap | undefined = undefined;
  @State private message: string = '';
  @State private busy: boolean = false;
  private owner: string = '';
  private generation: number = 0;

  aboutToDisappear(): void {
    this.generation++;
    this.clear();
  }
  private clear(): void {
    this.preview?.release().catch(() => {});
    this.preview = undefined;
    this.owner = '';
  }
  private async choose(): Promise<void> {
    if (this.busy || !this.online || !client.view.wallpaperAccountKey) { return; }
    const owner = client.view.wallpaperAccountKey;
    const run = this.generation;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true;
    let file: fileIo.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    let bitmap: image.PixelMap | undefined = undefined;
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['图片|.jpg,.jpeg,.png,.webp'];
      const uris = await new picker.DocumentViewPicker(context).select(options);
      if (run !== this.generation || uris.length !== 1 || owner !== client.view.wallpaperAccountKey) { return; }
      file = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(file.fd);
      if (!stat.isFile() || stat.size < 1 || stat.size > 30 * 1024 * 1024) { throw new Error('cover_size'); }
      source = image.createImageSource(file.fd);
      const info = await source.getImageInfo();
      const size = info.size;
      if (size.width < 2 || size.height < 2 || size.width * size.height > 64 * 1024 * 1024) { throw new Error('cover_dimensions'); }
      const scale = Math.min(1, 1600 / Math.max(size.width, size.height));
      bitmap = await source.createPixelMap({desiredSize: {
        width: Math.max(1, Math.round(size.width * scale)), height: Math.max(1, Math.round(size.height * scale))
      }});
      if (run !== this.generation || owner !== client.view.wallpaperAccountKey) { return; }
      this.clear();
      this.preview = bitmap; bitmap = undefined; this.owner = owner; this.message = '';
    } catch (_) {
      if (run === this.generation) { this.message = '无法读取这张图片，请选择其他图片。'; }
    } finally {
      if (bitmap) { await bitmap.release().catch(() => {}); }
      if (source) { await source.release().catch(() => {}); }
      if (file) { await fileIo.close(file).catch(() => {}); }
      if (run === this.generation) { this.busy = false; }
    }
  }
  private async publish(): Promise<void> {
    const picture = this.preview;
    const owner = this.owner;
    if (this.busy || !this.online || !picture || !owner || owner !== client.view.wallpaperAccountKey) { return; }
    const run = this.generation;
    this.busy = true;
    this.message = '正在同步…';
    const packer = image.createImagePacker();
    try {
      const data = await packer.packToData(picture, {format: 'image/jpeg', quality: 88});
      if (run !== this.generation || owner !== client.view.wallpaperAccountKey) { return; }
      const saved = await pcHost.publishCover(data);
      if (run === this.generation) { this.message = saved ? '设备封面已同步。' : '同步失败，请确认此电脑在线后重试。'; }
    } catch (_) {
      if (run === this.generation) { this.message = '同步失败，请重试。'; }
    } finally {
      await packer.release().catch(() => {});
      if (run === this.generation) { this.busy = false; }
    }
  }
  build() {
    Column({space: 10}) {
      Text('设备封面').fontSize(UiFont.heading).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
      Text('可选用和桌面相同的图片。确认同步后，图片将显示在 UU 设备卡片上。')
        .fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
      if (this.preview) {
        Image(this.preview).objectFit(ImageFit.Contain).width('100%').height(110)
      }
      Row({space: 8}) {
        Button('选择图片').enabled(this.online && !this.busy).onClick(() => { this.choose(); })
        if (this.preview) {
          Button('同步封面').enabled(this.online && !this.busy).onClick(() => { this.publish(); })
        }
      }.width('100%')
      if (this.message) { Text(this.message).fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%') }
    }.width('100%').padding(UiSpace.card).backgroundColor(UiColor.surface).borderRadius(UiSpace.radius)
  }
}
