import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import filesNative, { LocalDirectoryEntry } from 'libuufiles.so';
import { activateTransferFolder, appendTransferPath, chooseTransferFolder, configuredReceiveFolder,
  resolveLocalTransferPath, transferFolderLabel, transferLocations } from '../pc/PcTransferLocations';
import { PcFileRoute, pcFileWindows } from '../pc/PcFileWindows';
import { AdvancedCommand } from './AdvancedClient';
import { FileEntry, FilesCommand, FilesStatus, RemoteFiles } from './RemoteFiles';
import { session } from './SessionClient';
import { UiColor, UiFont } from './UiFoundation';
import { PcTransferHistory } from './TransferHistory';

@Entry
@Component
struct PcFileWindow {
  @State private localEntries: FileEntry[] = [];
  @State private remoteEntries: FileEntry[] = [];
  @State private localFolder: string = '';
  @State private localRoot: string = '';
  @State private remoteFolder: string = '';
  @State private localAddress: string = '';
  @State private remoteAddress: string = '';
  @State private galleryEnabled: boolean = true;
  @State private historyOpen: boolean = false;
  @State private left: string = '';
  @State private right: string = '';
  @State private targetName: string = '远端';
  @State private connected: boolean = false;
  @State private localLoading: boolean = false;
  @State private remoteBusy: boolean = false;
  @State private localMessage: string = '';
  @State private statusText: string = '正在连接远端电脑…';
  @State private progress: number = 0;
  @State private transfer: string = '';
  @State private canReconnect: boolean = false;
  private route: PcFileRoute | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private live: boolean = false;
  private generation: number = -1;
  private reconnecting: boolean = false;
  private timer: number = -1;
  private lastTask: string = '';
  private permittedRoots: string[] = [];
  private writableRoots: string[] = [];
  private files: RemoteFiles = new RemoteFiles((command: FilesCommand): Promise<string> => {
    const route = this.route;
    if (!route || this.generation !== session.generation || route.deviceKey !== session.selected) {
      return Promise.resolve('{"error":"session_changed"}');
    }
    const request: AdvancedCommand = {op: command.op, event: command.event};
    return route.borrowed ? session.advancedCommand(request) : session.filesCommand(request);
  });

  aboutToAppear(): void {
    this.route = pcFileWindows.route;
    this.live = true;
    this.targetName = this.route?.deviceName || '远端';
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.files.setContext(this.context);
    this.files.enableHistory();
    this.files.setForeground(true);
    this.files.observe((state: FilesStatus, message: string) => { this.update(state, message); });
    this.loadLocalStart();
    this.connect();
    this.timer = setInterval(() => { this.check(); }, 250);
  }

  private async connect(): Promise<void> {
    const route = this.route;
    if (!route || !this.live || this.reconnecting) { return; }
    if (route.borrowed) { this.generation = session.generation; return; }
    this.reconnecting = true;
    this.canReconnect = false;
    this.connected = false;
    this.statusText = '正在连接远端电脑…';
    try {
      if (session.filesOnly && session.generation === this.generation) { await session.cancel('user_disconnect'); }
      if (!this.live) { return; }
      if (!await session.select(route.deviceKey, route.deviceName, () => this.live)) {
        this.statusText = '设备暂不可用，请重试。';
        this.canReconnect = true;
        return;
      }
      if (!this.live) { return; }
      session.joinFilesConfirmed(route.deviceKey);
      this.generation = session.generation;
      this.remoteFolder = '';
      this.remoteAddress = '';
      this.remoteEntries = [];
      this.right = '';
    } finally {
      this.reconnecting = false;
    }
  }

  private check(): void {
    if (!this.live || this.reconnecting || !this.route) { return; }
    const matching = session.generation === this.generation && session.selected === this.route.deviceKey;
    const ready = matching && session.filesReady && session.filesOnly !== this.route.borrowed && session.appForeground;
    if (ready && !this.connected) {
      this.connected = true;
      this.canReconnect = false;
      this.files.list(this.remoteFolder);
    } else if (this.connected && (!matching || !session.busy)) {
      this.connected = false;
      this.files.connectionLost();
    }
    if (!this.connected && !session.busy && !session.isClosing && !matching) {
      this.statusText = '远端文件连接已断开。';
      this.canReconnect = !this.route.borrowed;
    }
  }

  aboutToDisappear(): void {
    this.live = false;
    if (this.timer >= 0) { clearInterval(this.timer); }
    this.release();
  }

  private async release(): Promise<void> {
    const generation = this.generation;
    if (this.route?.borrowed && generation === session.generation && this.remoteBusy) { await this.files.cancel(); }
    await this.files.dispose();
    if (this.route?.borrowed === false && generation === session.generation && session.filesOnly) {
      await session.cancel('user_disconnect');
    }
  }

  private update(state: FilesStatus, text: string): void {
    if (!this.live) { return; }
    this.remoteBusy = !['idle', 'complete', 'failed', 'canceled', 'disconnected'].includes(state.state);
    this.canReconnect = !this.route?.borrowed && (state.requiresReconnect === true || state.state === 'disconnected');
    this.statusText = state.requiresReconnect && this.route?.borrowed ? text + ' 请重新连接远程桌面。' : text;
    if (state.mode === 'list' && state.state === 'complete') {
      this.remoteFolder = state.directory;
      this.remoteAddress = state.directory;
      this.remoteEntries = this.sorted(state.entries);
    }
    this.progress = state.total > 0 ? Math.min(100, state.transferred * 100 / state.total) : 0;
    this.transfer = this.remoteBusy && state.mode !== 'list' && state.name ?
      state.name + ' · ' + this.bytes(state.transferred) + ' / ' + this.bytes(state.total) : '';
    const key = state.generation + ':' + state.task;
    if (state.mode !== 'list' && state.name && (state.state === 'complete' || state.state === 'failed') && this.lastTask !== key) {
      this.lastTask = key;
      if (state.mode === 'download' && state.localSaved) { this.readLocal(this.localFolder); }
      if (state.mode === 'upload' && state.state === 'complete') {
        setTimeout(() => { if (this.live && !this.remoteBusy) { this.files.list(this.remoteFolder); } }, 100);
      }
    }
  }

  private async loadLocalStart(): Promise<void> {
    const context = this.context;
    if (!context) { return; }
    const locations = transferLocations(context);
    this.galleryEnabled = locations.gallery;
    const receive = await configuredReceiveFolder(context, false).catch(() => '');
    if (!this.live) { return; }
    if (receive) { this.rememberRoot(receive, true); }
    if (locations.source) {
      try {
        await activateTransferFolder(locations.source, false);
        if (this.live && !this.localFolder && await this.readLocal(locations.source)) {
          this.rememberRoot(locations.source, false);
          return;
        }
      } catch (_) {}
    }
    if (receive && !this.localFolder) { await this.readLocal(receive); }
  }

  private rememberRoot(folder: string, writable: boolean): void {
    if (!this.permittedRoots.includes(folder)) { this.permittedRoots = [folder, ...this.permittedRoots]; }
    if (writable && !this.writableRoots.includes(folder)) { this.writableRoots = [folder, ...this.writableRoots]; }
    this.localRoot = folder;
  }
  private canReceiveHere(): boolean {
    return this.writableRoots.some((root: string) => this.localFolder === root || this.localFolder.startsWith(root + '/'));
  }

  private async defaultFolder(request: boolean): Promise<void> {
    const context = this.context;
    if (!context || this.localLoading) { return; }
    this.localLoading = true;
    let folder: string = '';
    try { folder = await configuredReceiveFolder(context, request); } catch (_) {}
    this.localLoading = false;
    if (!this.live) { return; }
    if (folder) {
      if (await this.readLocal(folder)) { this.rememberRoot(folder, true); }
    } else if (request) {
      this.localMessage = '无法访问接收文件夹，请在传输设置重新授权，或在这里临时选择。';
    }
  }

  private async chooseFolder(): Promise<void> {
    const context = this.context;
    if (!context || this.localLoading) { return; }
    this.localLoading = true;
    let chosen: string = '';
    try {
      chosen = (await chooseTransferFolder(context, true, false)).replace(/\/+$/, '');
    } catch (_) { this.localMessage = '无法打开目录选择器。'; }
    this.localLoading = false;
    if (this.live && chosen && await this.readLocal(chosen)) { this.rememberRoot(chosen, true); }
  }

  private async readLocal(folder: string): Promise<boolean> {
    if (!folder || !this.live || this.localLoading) { return false; }
    this.localLoading = true;
    this.localMessage = '';
    try {
      const directory = await fileIo.open(folder, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      let entries: FileEntry[];
      try {
        if (!this.live) { return false; }
        entries = filesNative.listDirectory(directory.fd).map((item: LocalDirectoryEntry): FileEntry => {
          const path = appendTransferPath(folder, item.name);
          return {kind: item.kind, name: item.name, path: path, size: item.size, modified: item.modified};
        });
      } finally { await fileIo.close(directory); }
      if (!this.live) { return false; }
      this.localFolder = folder;
      this.localAddress = transferFolderLabel(folder);
      this.localEntries = this.sorted(entries);
      this.left = '';
      return true;
    } catch (_) {
      this.localMessage = '当前目录无法读取，请选择具有读写权限的目录。';
      return false;
    } finally { this.localLoading = false; }
  }

  private regular(item: FileEntry): boolean { return item.kind === 4 || item.kind === 5; }
  private sorted(items: FileEntry[]): FileEntry[] {
    return items.slice().sort((a: FileEntry, b: FileEntry) =>
      Number(this.regular(a)) - Number(this.regular(b)) || a.name.localeCompare(b.name, 'zh-CN'));
  }
  private bytes(size: number): string {
    if (size >= 1048576) { return (size / 1048576).toFixed(1) + ' MB'; }
    if (size >= 1024) { return (size / 1024).toFixed(1) + ' KB'; }
    return size + ' B';
  }
  private async goLocal(): Promise<void> {
    if (this.remoteBusy || this.localLoading) { return; }
    const path = resolveLocalTransferPath(this.localAddress, this.permittedRoots);
    if (!path) {
      this.localMessage = '请先通过系统选择该文件夹，或输入已授权文件夹下的路径。';
      return;
    }
    if (await this.readLocal(path)) {
      const root = this.permittedRoots.find((item: string) => path === item || path.startsWith(item + '/'));
      if (root) { this.localRoot = root; }
    }
  }

  private goRemote(path: string): void {
    if (this.remoteBusy || !this.connected) { return; }
    const target = path.trim();
    if (target === this.remoteFolder) { this.files.list(target); return; }
    this.right = '';
    this.files.list(target);
  }

  private openItem(local: boolean, item: FileEntry): void {
    if (this.remoteBusy || (local && this.localLoading)) { return; }
    if (this.regular(item)) {
      if (local) { this.left = item.path; } else { this.right = item.path; }
    } else if (local) {
      this.readLocal(item.path);
    } else if (this.connected) {
      this.goRemote(item.path);
    }
  }

  private parentRemote(): void {
    const path = this.remoteFolder.replace(/[\\/]+$/, '');
    const separator = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    if (separator < 0) { this.goRemote(''); return; }
    this.goRemote(path.slice(0, separator === 2 && path[1] === ':' ? 3 : Math.max(1, separator)));
  }

  private async sendSelected(): Promise<void> {
    const item = this.localEntries.find((entry: FileEntry) => entry.path === this.left);
    if (!item || !this.remoteFolder || !this.connected || this.remoteBusy) { return; }
    await this.files.selectLocalUpload(item.path, item.name, this.remoteFolder);
    if (this.live && this.files.choice) { await this.files.confirmUpload(); }
  }

  private async sendGallery(): Promise<void> {
    if (!this.remoteFolder || !this.connected || this.remoteBusy) { return; }
    const directory = this.remoteFolder;
    await this.files.selectUpload(directory, true);
    if (this.live && this.files.choice && this.remoteFolder === directory) { await this.files.confirmUpload(); }
  }

  private receiveSelected(): void {
    const item = this.remoteEntries.find((entry: FileEntry) => entry.path === this.right);
    const root = this.writableRoots.find((folder: string) => this.localFolder === folder || this.localFolder.startsWith(folder + '/'));
    if (item && root && this.connected && !this.remoteBusy) { this.files.download(item, false, this.localFolder, root); }
  }

  @Builder private pane(local: boolean) {
    Column({space: 8}) {
      Row({space: 12}) {
        Text(local ? '本机 · HarmonyOS' : this.targetName).fontSize(UiFont.heading).fontWeight(FontWeight.Bold)
          .fontColor(UiColor.text).layoutWeight(1).maxLines(1).textOverflow({overflow: TextOverflow.Ellipsis})
        if (local) {
          Button('接收位置').enabled(!this.localLoading && !this.remoteBusy).onClick(() => { this.defaultFolder(true); })
          Button('选择文件夹').enabled(!this.localLoading && !this.remoteBusy).onClick(() => { this.chooseFolder(); })
        } else {
          Button('浏览位置').enabled(this.connected && !this.remoteBusy).onClick(() => { this.goRemote(''); })
        }
      }.width('100%')
      Row({space: 8}) {
        Button('上一级').enabled(local ? !!this.localRoot && this.localFolder !== this.localRoot &&
          !this.localLoading && !this.remoteBusy : !!this.remoteFolder && this.connected && !this.remoteBusy)
          .onClick(() => {
            if (local) { this.readLocal(this.localFolder.slice(0, this.localFolder.lastIndexOf('/'))); }
            else { this.parentRemote(); }
          })
        Button('刷新').enabled(local ? !!this.localFolder && !this.localLoading : this.connected && !this.remoteBusy)
          .onClick(() => { if (local) { this.readLocal(this.localFolder); } else { this.files.list(this.remoteFolder); } })
        if (local && this.localFolder && !this.canReceiveHere()) {
          Text('发送文件夹').fontSize(UiFont.caption).fontColor(UiColor.secondary)
        }
      }.width('100%')
      Row({space: 8}) {
        TextInput({text: local ? this.localAddress : this.remoteAddress, placeholder: local ? '本机路径' : '此电脑'})
          .layoutWeight(1).height(38).fontSize(UiFont.caption).enterKeyType(EnterKeyType.Go)
          .enabled(!this.remoteBusy && (local ? !this.localLoading : this.connected))
          .onChange((value: string) => { if (local) { this.localAddress = value; } else { this.remoteAddress = value; } })
          .onSubmit(() => { if (local) { this.goLocal(); } else { this.goRemote(this.remoteAddress); } })
        Button('前往').enabled(!this.remoteBusy && (local ? !this.localLoading : this.connected))
          .onClick(() => { if (local) { this.goLocal(); } else { this.goRemote(this.remoteAddress); } })
      }.width('100%')
      if (local && this.localMessage) { Text(this.localMessage).fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%') }
      Row() {
        Text('名称').layoutWeight(1).fontColor(UiColor.secondary)
        Text('大小').width(86).textAlign(TextAlign.End).fontColor(UiColor.secondary)
      }.width('100%').padding({left: 12, right: 12, top: 6, bottom: 6})
      List() {
        ForEach(local ? this.localEntries : this.remoteEntries, (item: FileEntry) => {
          ListItem() {
            Row({space: 8}) {
              Image(this.regular(item) ? $r('app.media.transfer_document') : $r('app.media.transfer_folder'))
                .width(22).height(22).accessibilityText(this.regular(item) ? '文件' : '文件夹')
              Text(item.name).fontSize(UiFont.body).fontColor(UiColor.text).layoutWeight(1).maxLines(1)
                .textOverflow({overflow: TextOverflow.Ellipsis})
              Text(this.regular(item) ? this.bytes(item.size) : '进入 ›').fontSize(UiFont.caption)
                .fontColor(UiColor.secondary).width(86).textAlign(TextAlign.End)
            }.width('100%').height(36).padding({left: 12, right: 12})
              .backgroundColor(item.path === (local ? this.left : this.right) ? UiColor.primarySoft : UiColor.surface)
              .borderRadius(6).onClick(() => { this.openItem(local, item); })
          }
        }, (item: FileEntry) => item.path)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      if ((local ? this.localEntries.length : this.remoteEntries.length) === 0) {
        Text(local && !this.localFolder ? '选择本机目录后可收发文件' : '当前没有文件')
          .fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
      }
    }.layoutWeight(1).height('100%').padding(12).borderRadius(12).backgroundColor(UiColor.surface)
  }

  build() {
    Stack() {
    if (this.historyOpen) {
      PcTransferHistory({onClose: () => { this.historyOpen = false; }})
    } else {
    Column({space: 10}) {
      Row({space: 10}) {
        Button('发送到远端 →').enabled(this.connected && !this.remoteBusy && !!this.left && !!this.remoteFolder)
          .onClick(() => { this.sendSelected(); })
        Button('← 接收到本机').enabled(this.connected && !this.remoteBusy && !!this.right && this.canReceiveHere() && !this.localLoading)
          .onClick(() => { this.receiveSelected(); })
        if (this.galleryEnabled) {
          Button('从图库发送').enabled(this.connected && !this.remoteBusy && !!this.remoteFolder)
            .onClick(() => { this.sendGallery(); })
        }
        Blank()
        Button('传输历史').onClick(() => { this.historyOpen = true; })
        if (this.canReconnect) { Button('重新连接').onClick(() => { this.connect(); }) }
        if (this.remoteBusy) { Button('取消任务').onClick(() => { this.files.cancel(); }) }
      }.width('100%')
      Row({space: 12}) { this.pane(true); this.pane(false) }.width('100%').layoutWeight(1)
      Column({space: 4}) {
        Row({space: 12}) {
          Text('传输状态').fontSize(UiFont.heading).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
          Text(this.transfer || this.statusText).fontSize(UiFont.caption).fontColor(UiColor.secondary)
            .layoutWeight(1).maxLines(1).textOverflow({overflow: TextOverflow.Ellipsis})
        }.width('100%')
        if (this.remoteBusy && this.transfer) {
          Progress({value: this.progress, total: 100, type: ProgressType.Linear}).width('100%')
        }
        if (this.transfer) { Text(this.statusText).fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%') }
      }.width('100%').padding(12).backgroundColor(UiColor.surface).borderRadius(12)
    }.width('100%').height('100%').padding(14).backgroundColor(UiColor.background)
    }
    }.width('100%').height('100%')
  }
}
