import { common } from '@kit.AbilityKit';
import { TransferRecord, hasReceivedFile, importLegacyHistory, readTransferHistory, removeTransferRecord } from '../pc/PcTransferHistory';
import { transferFolderLabel } from '../pc/PcTransferLocations';
import { UiColor, UiFont } from './UiFoundation';

@Component
export struct PcTransferHistory {
  onClose: () => void = () => {};
  @State private records: TransferRecord[] = [];
  @State private selected: string[] = [];
  @State private query: string = '';
  @State private busy: boolean = false;
  @State private message: string = '';
  @State private toRemove: TransferRecord[] = [];
  private context: common.UIAbilityContext | undefined = undefined;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.refresh();
  }
  private async refresh(): Promise<void> {
    if (!this.context) { return; }
    await importLegacyHistory(this.context).catch(()=>{this.message='部分旧收件记录未导入，可刷新重试。';});
    this.records = await readTransferHistory(this.context).catch(() => {
      this.message = '传输历史暂时无法读取。';
      return this.records;
    });
    this.selected = this.selected.filter((id: string) => this.records.some((item: TransferRecord) => item.id === id));
  }
  private visibleRecords(): TransferRecord[] {
    const query = this.query.trim().toLowerCase();
    return query ? this.records.filter((item: TransferRecord) => item.name.toLowerCase().includes(query)) : this.records;
  }
  private toggle(id: string, checked: boolean): void {
    this.selected = checked ? Array.from(new Set<string>([...this.selected, id])) :
      this.selected.filter((value: string) => value !== id);
  }
  private ask(records: TransferRecord[]): void {
    if (!this.busy && records.length > 0) { this.toRemove = records; }
  }
  private async clear(removeFiles: boolean): Promise<void> {
    const context = this.context;
    if (!context || this.busy) { return; }
    const records = this.toRemove;
    this.toRemove = [];
    this.busy = true;
    let cleared = 0;
    try {
      for (const record of records) {
        if (await removeTransferRecord(context, record, removeFiles)) { cleared++; }
      }
      await this.refresh();
      this.message = cleared === records.length ? '已清除 ' + cleared + ' 条记录。' :
        '已清除 ' + cleared + ' 条。其余文件已变化或目录无法访问，记录已保留。';
    } finally { this.busy = false; }
  }
  @Builder private confirmClear() {
    Column({space: 12}) {
      Text('清除 ' + this.toRemove.length + ' 条传输记录？').fontSize(UiFont.heading)
        .fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
      Text('同时删除仅适用于记录中仍可核对的本机收件。已发送的源文件和远端文件会保留。')
        .fontSize(UiFont.body).fontColor(UiColor.secondary).width('100%')
      Flex({wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End}) {
        Button('取消').margin(4).onClick(() => { this.toRemove = []; })
        Button('仅清除记录').margin(4).onClick(() => { this.clear(false); })
        Button('同时删除本机收件').margin(4).fontColor(UiColor.error).backgroundColor(UiColor.errorSoft)
          .enabled(this.toRemove.some((item: TransferRecord) => hasReceivedFile(item))).onClick(() => { this.clear(true); })
      }.width('100%')
    }.width('90%').constraintSize({maxWidth: 540}).padding(20).borderRadius(16).backgroundColor(UiColor.surface)
  }
  build() {
    Stack() {
      Column({space: 12}) {
        Row({space: 10}) {
          Button('返回').enabled(!this.busy).onClick(this.onClose)
          Text('传输历史').fontSize(UiFont.title).fontWeight(FontWeight.Bold).fontColor(UiColor.text).layoutWeight(1)
          Button('刷新').enabled(!this.busy).onClick(() => { this.refresh(); })
        }.width('100%')
        Row({space: 10}) {
          Search({value: this.query, placeholder: '搜索文件名'}).layoutWeight(1).onChange((value: string) => { this.query = value; })
          Button('选择当前结果').enabled(!this.busy && this.visibleRecords().length > 0)
            .onClick(() => { this.selected = this.visibleRecords().map((item: TransferRecord) => item.id); })
          Button('清除所选 ' + this.selected.length).enabled(!this.busy && this.selected.length > 0)
            .onClick(() => { this.ask(this.records.filter((item: TransferRecord) => this.selected.includes(item.id))); })
        }.width('100%')
        if (this.message) { Text(this.message).width('100%').fontSize(UiFont.caption).fontColor(UiColor.secondary) }
        if (this.visibleRecords().length === 0) {
          Text('暂无匹配的传输记录').width('100%').padding(20).fontColor(UiColor.secondary)
        }
        List({space: 4}) {
          ForEach(this.visibleRecords(), (item: TransferRecord) => {
            ListItem() {
              Row({space: 10}) {
                Checkbox().select(this.selected.includes(item.id)).accessibilityText('选择 ' + item.name)
                  .enabled(!this.busy).onChange((checked: boolean) => { this.toggle(item.id, checked); })
                Column({space: 4}) {
                  Text(item.name).fontSize(UiFont.body).fontColor(UiColor.text).width('100%').maxLines(1)
                    .textOverflow({overflow: TextOverflow.Ellipsis})
                  Text((item.direction === 'receive' ? '接收' : '发送') + (item.state === 'complete' ? '完成' : '失败') +
                    ' · ' + new Date(item.time).toLocaleString() + ' · ' + item.size + ' B')
                    .fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
                  if (item.root) {
                    Text((item.id.startsWith('legacy-')?'旧收件目录':transferFolderLabel(item.root)) + (item.branch.length ? '/' + item.branch.join('/') : ''))
                      .fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%').maxLines(1)
                      .textOverflow({overflow: TextOverflow.Ellipsis})
                  }
                }.layoutWeight(1)
                Button('清除').enabled(!this.busy).onClick(() => { this.ask([item]); })
              }.width('100%').padding(10).borderRadius(8).backgroundColor(UiColor.surface)
            }
          }, (item: TransferRecord) => item.id)
        }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      }.padding(16).width('100%').height('100%').backgroundColor(UiColor.background)
      if (this.toRemove.length > 0) {
        Stack() { this.confirmClear() }.width('100%').height('100%').backgroundColor('#66000000')
      }
    }.width('100%').height('100%')
  }
}

@Entry
@Component
struct TransferHistoryPage {
  build() {
    Column() { PcTransferHistory({onClose: () => { this.getUIContext().getRouter().back(); }}) }
      .width('100%').height('100%')
  }
}
