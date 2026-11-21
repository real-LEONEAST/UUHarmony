import { UiPalette, uiPalette } from './UiFoundation';

export interface UiDialogOptions {
  title: string;
  message: string;
  cancel?: () => void;
  primaryButton?: AlertDialogButtonOptions;
  secondaryButton?: AlertDialogButtonOptions;
  buttons?: AlertDialogButtonOptions[];
}

@CustomDialog
export struct UiThemeDialog {
  controller?: CustomDialogController;
  dark: boolean = false;
  options: UiDialogOptions = { title: '', message: '' };
  private colors(): UiPalette { return uiPalette(this.dark); }
  private actions(): AlertDialogButtonOptions[] {
    if (this.options.buttons) { return this.options.buttons; }
    const result: AlertDialogButtonOptions[] = [];
    if (this.options.primaryButton) { result.push(this.options.primaryButton); }
    if (this.options.secondaryButton) { result.push(this.options.secondaryButton); }
    return result;
  }
  build() {
    Scroll() {
    Column({ space: 16 }) {
      Text(this.options.title).fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.colors().text).width('100%')
      Text(this.options.message).fontSize(16).fontColor(this.colors().secondary).width('100%')
      ForEach(this.actions(), (button: AlertDialogButtonOptions) => {
        Button(button.value).fontSize(16).fontColor(this.colors().primary).backgroundColor(this.colors().primarySoft)
          .width('100%').height('auto').constraintSize({ minHeight: 48 }).padding(12).borderRadius(12)
          .onClick(() => { this.controller?.close(); button.action(); })
      })
    }.padding(24).width('100%')
    }.width('90%').constraintSize({ maxWidth: 480, maxHeight: '90%' }).scrollBar(BarState.Off)
      .borderRadius(22).clip(true).backgroundColor(this.colors().surface)
  }
}
