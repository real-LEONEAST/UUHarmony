// UI-1 foundation. Semantic resources include a dark appearance; text follows system scaling.
export class UiSpace {
  static readonly page: number = 24;
  static readonly card: number = 20;
  static readonly gap: number = 12;
  static readonly radius: number = 18;
  static readonly buttonRadius: number = 14;
}
export class UiFont {
  static readonly title: number = 28;
  static readonly heading: number = 18;
  static readonly body: number = 16;
  static readonly caption: number = 13;
  static readonly action: number = 16;
}
export class UiColor {
  static readonly background: ResourceColor = $r('app.color.ui_background');
  static readonly divider: ResourceColor = $r('app.color.ui_divider');
  static readonly surface: ResourceColor = $r('app.color.ui_surface');
  static readonly text: ResourceColor = $r('app.color.ui_text');
  static readonly secondary: ResourceColor = $r('app.color.ui_secondary');
  static readonly primary: ResourceColor = $r('app.color.ui_primary');
  static readonly onPrimary: ResourceColor = $r('app.color.ui_on_primary');
  static readonly primarySoft: ResourceColor = $r('app.color.ui_primary_soft');
  static readonly neutralSoft: ResourceColor = $r('app.color.ui_neutral_soft');
  static readonly success: ResourceColor = $r('app.color.ui_success');
  static readonly successSoft: ResourceColor = $r('app.color.ui_success_soft');
  static readonly warning: ResourceColor = $r('app.color.ui_warning');
  static readonly warningSoft: ResourceColor = $r('app.color.ui_warning_soft');
  static readonly error: ResourceColor = $r('app.color.ui_error');
  static readonly errorSoft: ResourceColor = $r('app.color.ui_error_soft');
}

// Library and remote controls share semantic resources and application appearance.
export class UiPalette {
  background: ResourceColor = UiColor.background;
  divider: ResourceColor = UiColor.divider;
  surface: ResourceColor = UiColor.surface;
  text: ResourceColor = UiColor.text;
  secondary: ResourceColor = UiColor.secondary;
  primary: ResourceColor = UiColor.primary;
  onPrimary: ResourceColor = UiColor.onPrimary;
  primarySoft: ResourceColor = UiColor.primarySoft;
  neutralSoft: ResourceColor = UiColor.neutralSoft;
  success: ResourceColor = UiColor.success;
  successSoft: ResourceColor = UiColor.successSoft;
  warning: ResourceColor = UiColor.warning;
  warningSoft: ResourceColor = UiColor.warningSoft;
  error: ResourceColor = UiColor.error;
  errorSoft: ResourceColor = UiColor.errorSoft;
  constructor(remote: boolean = false) {

  }
}
const systemPalette: UiPalette = new UiPalette();
const remotePalette: UiPalette = new UiPalette(true);
export function uiPalette(remote: boolean = false): UiPalette { return remote ? remotePalette : systemPalette; }

@Component
export struct UiStatusBadge {
  @Prop label: string = '';
  @Prop tone: string = 'unknown';
  private ink(): ResourceColor { return this.tone === 'online' ? UiColor.success : UiColor.secondary; }
  build() {
    Row({ space: 6 }) {
      Circle().width(6).height(6).fill(this.ink()).accessibilityLevel('no')
      Text(this.label).fontSize(UiFont.caption).fontWeight(FontWeight.Medium).fontColor(this.ink())
    }.padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor(this.tone === 'online' ? UiColor.successSoft : UiColor.neutralSoft).borderRadius(10)
  }
}

@Component
export struct UiActionButton {
  @Prop label: string = '';
  @Prop available: boolean = true;
  onAction: () => void = () => {};
  build() {
    Button({ type: ButtonType.Normal }) {
      Text(this.label).fontSize(UiFont.action).fontWeight(FontWeight.Medium).fontColor(UiColor.onPrimary)
        .textAlign(TextAlign.Center).width('100%')
    }.width('100%').height('auto').constraintSize({ minHeight: 48 }).padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .borderRadius(UiSpace.buttonRadius).backgroundColor(UiColor.primary).enabled(this.available)
      .onClick(() => this.onAction())
  }
}

@Component
export struct UiNotice {
  @Prop text: string = '';
  @Prop tone: string = 'warning';
  build() {
    Text(this.text).fontSize(UiFont.body).fontColor(this.tone === 'error' ? UiColor.error : UiColor.warning)
      .width('100%').padding(14).borderRadius(14)
      .backgroundColor(this.tone === 'error' ? UiColor.errorSoft : UiColor.warningSoft)
  }
}

@Component
export struct UiSecondaryButton {
  @Prop label: string = '';
  @Prop available: boolean = true;
  onAction: () => void = () => {};
  build() {
    Button({ type: ButtonType.Normal }) {
      Text(this.label).fontSize(UiFont.action).fontWeight(FontWeight.Medium).fontColor(UiColor.primary)
        .textAlign(TextAlign.Center).width('100%')
    }.width('100%').height('auto').constraintSize({ minHeight: 48 }).padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .borderRadius(UiSpace.buttonRadius).backgroundColor(UiColor.primarySoft).enabled(this.available)
      .onClick(() => this.onAction())
  }
}
