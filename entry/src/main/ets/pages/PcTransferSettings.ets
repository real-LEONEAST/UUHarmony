import { common } from '@kit.AbilityKit';
import { chooseTransferFolder, saveTransferLocation, transferFolderLabel, transferLocations } from '../pc/PcTransferLocations';
import { UiColor, UiFont } from './UiFoundation';

@Component
export struct PcTransferSettings {
  @Prop receiving: boolean = false;
  onChange: () => void = () => {};
  @State private receive: string = '';
  @State private source: string = '';
  @State private gallery: boolean = true;
  @State private busy: boolean = false;
  @State private message: string = '';
  private context: common.UIAbilityContext | undefined = undefined;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.refresh();
  }
  private refresh(): void {
    if (!this.context) { return; }
    const locations = transferLocations(this.context);
    this.receive = locations.receive;
    this.source = locations.source;
    this.gallery = locations.gallery;
  }
  private async change(key: string, select: boolean, gallery: boolean = this.gallery): Promise<void> {
    const context = this.context;
    if (!context || this.busy || (key === 'receive' && this.receiving)) { return; }
    this.busy = true;
    this.message = '';
    try {
      const value = key === 'gallery' ? gallery : select ? await chooseTransferFolder(context, key === 'receive', true) : '';
      if (select && !value) { return; }
      await saveTransferLocation(context, key, value);
      this.refresh();
      this.onChange();
    } catch (_) {
      this.refresh();
      this.message = '系统未授予该位置的持久访问权限。请选择其他文件夹，或在文件窗口临时选择。';
    } finally { this.busy = false; }
  }
  @Builder private location(title: string, label: string, key: string, enabled: boolean) {
    Column({space: 5}) {
      Text(title).fontSize(UiFont.body).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
      Text(label).fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
        .maxLines(2).textOverflow({overflow: TextOverflow.Ellipsis})
      Row({space: 8}) {
        Button('选择文件夹').enabled(enabled && !this.busy).onClick(() => { this.change(key, true); })
        Button(key === 'receive' ? '恢复默认' : '清除选择').enabled(enabled && !this.busy &&
          (key === 'receive' ? !!this.receive : !!this.source)).onClick(() => { this.change(key, false); })
      }.width('100%')
    }.width('100%')
  }
  build() {
    Column({space: 14}) {
      this.location('接收文件夹', this.receive ? transferFolderLabel(this.receive) : '下载 / UUHarmony',
        'receive', !this.receiving)
      if (this.receiving) {
        Text('关闭接收后可更改接收文件夹。').fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
      }
      Divider()
      this.location('发送文件夹', this.source ? transferFolderLabel(this.source) : '在传输窗口选择文件夹',
        'source', true)
      Row({space: 8}) {
        Text('从图库选择照片和视频').fontSize(UiFont.body).fontColor(UiColor.text).layoutWeight(1)
        Toggle({type: ToggleType.Switch, isOn: this.gallery}).enabled(!this.busy)
          .onChange((value: boolean) => { if (value !== this.gallery) { this.change('gallery', false, value); } })
      }.width('100%')
      if (this.gallery) {
        Text('发送时由系统图库授权所选照片或视频。').fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
      }
      if (this.message) {
        Text(this.message).fontSize(UiFont.caption).fontColor(UiColor.error).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
