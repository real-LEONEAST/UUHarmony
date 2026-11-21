import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import type { PcReceiveNative } from '../pc/PcReceiveNative';
import { configuredReceiveFolder } from '../pc/PcTransferLocations';
import { PcTransferSettings } from './PcTransferSettings';
import { UiColor, UiFont, UiSpace } from './UiFoundation';

@Component
export struct PcReceivedFiles {
  @Prop @Watch('syncPermission') sharingOpen: boolean = false;
  @State private available: boolean = false;
  @State private receiving: boolean = false;
  @State private changing: boolean = false;
  @State private message: string = '';
  @State private showSettings: boolean = false;
  private native: PcReceiveNative | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private generation: number = 0;

  aboutToAppear(): void {
    const generation = ++this.generation;
    this.changing = false;
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!this.context) { return; }
    import('../pc/PcReceiveNative').then((module) => {
      if (generation !== this.generation) { return; }
      this.native = module.receiveNative;
      this.available = true;
      this.syncPermission();
    }).catch(() => {
      if (generation === this.generation) { this.message = '接收文件功能暂不可用。'; }
    });
  }

  aboutToDisappear(): void {
    this.generation++;
  }

  private syncPermission(): void {
    this.receiving = this.sharingOpen && this.native?.isReceiving() === true;
  }

  private async toggleReception(): Promise<void> {
    const native = this.native;
    if (!native || this.changing || (!this.sharingOpen && !this.receiving)) { return; }
    const next = !this.receiving;
    const generation = this.generation;
    this.changing = true;
    this.message = '';
    try {
      const context = this.context;
      const root = next && context ? await configuredReceiveFolder(context, true) : '';
      if (generation !== this.generation) { return; }
      if (next && !root) { this.message = '请授权接收文件夹后再开启接收。'; return; }
      let code: number;
      if (next) {
        const directory = await fileIo.open(root, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
        try { code = generation === this.generation ? await native.setReceiving(true, directory.fd, root) : -1; }
        finally { await fileIo.close(directory); }
      } else {
        code = await native.setReceiving(false);
      }
      if (generation !== this.generation) { return; }
      this.syncPermission();
      if (code !== 0) { this.message = '未能更新接收权限，请确认共享服务已上线后重试。'; }
    } catch (_) {
      if (generation === this.generation) { this.message = '未能更新接收权限，请重试。'; }
    } finally {
      if (generation === this.generation) { this.changing = false; }
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('文件传输').fontSize(UiFont.heading).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Text('允许 Windows 发送文件').fontSize(UiFont.body).fontColor(UiColor.text).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.receiving })
            .enabled(this.available && !this.changing && (this.sharingOpen || this.receiving))
            .accessibilityText('允许 Windows 发送文件')
            .onChange((enabled: boolean) => { if (enabled !== this.receiving) { this.toggleReception(); } })
        }.width('100%')
        Text(this.receiving ? '从 Windows 发送到 UUHarmony。完成后可在传输历史查看。' :
          '共享上线后可开启，文件直接保存到所选接收文件夹。')
          .fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
        Row({space: 8}) {
          Button(this.showSettings ? '收起设置' : '传输设置').onClick(() => { this.showSettings = !this.showSettings; })
          Button('传输历史').onClick(() => { this.getUIContext().getRouter().pushUrl({url: 'pages/TransferHistory'}).catch(() => {}); })
        }.width('100%')
        if (this.showSettings) {
          PcTransferSettings({receiving: this.receiving || this.changing})
        }
        if (this.message) {
          Text(this.message).fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
        }
      }.padding(UiSpace.card).width('100%').backgroundColor(UiColor.surface).borderRadius(UiSpace.radius)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
