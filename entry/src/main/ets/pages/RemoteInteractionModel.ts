import { TouchMode } from './MobileTouch';

// Device-independent local choices. Window size never changes an input choice.
export class RemoteInputPreferences {
  mode: TouchMode = TouchMode.Direct;
  speed: number = 1;
  mouseSize: number = 1;
  mouseOpacity: number = 0.8;
  mouseX: number = 20;
  mouseY: number = 30;
}

export function normalizeInputPreferences(mode: string, speed: number): RemoteInputPreferences {
  const value = new RemoteInputPreferences();
  value.mode = mode === TouchMode.Trackpad ? TouchMode.Trackpad : mode === TouchMode.VirtualMouse ? TouchMode.VirtualMouse : mode === TouchMode.Tablet ? TouchMode.Tablet : TouchMode.Direct;
  value.speed = Number.isFinite(speed) ? Math.max(0.3, Math.min(3, speed)) : 1;
  return value;
}

// A saved tablet preference is restored only after this session reports support.
export function effectiveInputMode(preferred:TouchMode,support:number):TouchMode {
  return preferred===TouchMode.Tablet&&support!==2?TouchMode.Direct:preferred;
}

export function inputModeLabel(mode: TouchMode): string {
  return mode === TouchMode.Trackpad ? '触控板' : mode === TouchMode.VirtualMouse ? '虚拟鼠标' : mode === TouchMode.Tablet ? '平板触控' : '屏幕触控';
}

export class RemoteInteractionState {
  mode: TouchMode = TouchMode.Direct;
  visible: boolean = true;
  ready: boolean = false;
  exiting: boolean = false;
  confirming: boolean = false;
  failure: string = '';
  displayPending: boolean = false;
  displayBlocked: boolean = false;
  displayError: string = '';
  watch: boolean = false;
  viewOnly: boolean = false;
  panel: string = '';
  keyboard: boolean = false;
  externalKeyboard: boolean = false;
  canvasFocused: boolean = false;
}

export type InteractionTone = 'ready' | 'paused' | 'warning' | 'error';

export class RemoteInteractionFeedback {
  title: string = '';
  detail: string = '';
  tone: InteractionTone = 'paused';

  constructor(title: string, detail: string, tone: InteractionTone) {
    this.title = title;
    this.detail = detail;
    this.tone = tone;
  }
}

// The UI reports local input eligibility, never a remote execution acknowledgement.
export function interactionFeedback(state: RemoteInteractionState): RemoteInteractionFeedback {
  if (state.exiting) {
    return new RemoteInteractionFeedback('正在断开连接', '正在释放输入并结束远程会话。', 'paused');
  }
  if (state.confirming) {
    return new RemoteInteractionFeedback('操作已暂停', '确认是否断开连接，取消后可继续使用。', 'paused');
  }
  if (state.failure.length > 0) {
    return new RemoteInteractionFeedback('连接已中断', '当前无法操作，请返回设备列表重新连接。', 'error');
  }
  if (!state.visible) {
    return new RemoteInteractionFeedback('操作已暂停', '返回远程桌面后继续操作。', 'paused');
  }
  if (!state.ready) {
    return new RemoteInteractionFeedback('正在准备远程桌面', '收到画面并建立输入通道后即可操作。', 'paused');
  }
  if (state.displayError.length > 0) {
    return new RemoteInteractionFeedback('切屏未完成', '请打开显示器面板重新选择屏幕，当前输入已暂停。', 'warning');
  }
  if (state.displayPending) {
    return new RemoteInteractionFeedback('正在切换屏幕', '等待新屏幕画面，当前输入已暂停。', 'paused');
  }
  if (state.displayBlocked) {
    return new RemoteInteractionFeedback('等待新屏幕画面', '确认当前屏幕后恢复操作。', 'paused');
  }
  if (state.watch) {
    return new RemoteInteractionFeedback('仅观看', '远程输入已暂停，选择“恢复操作”后继续。', 'paused');
  }
  if (state.viewOnly) {
    return new RemoteInteractionFeedback('缩放与平移', '当前手势仅调整本地画面，选择“恢复操作”继续远控。', 'paused');
  }
  if (state.panel.length > 0) {
    return new RemoteInteractionFeedback('操作已暂停', '关闭' + state.panel + '后自动恢复桌面操作。', 'paused');
  }
  if (state.keyboard) {
    return new RemoteInteractionFeedback('键盘输入', '桌面触控已暂停；完成选词后点击发送，关闭键盘恢复。', 'paused');
  }
  if (state.externalKeyboard && !state.canvasFocused) {
    return new RemoteInteractionFeedback(inputModeLabel(state.mode) + ' · 可操作', '外接键盘待获取焦点，点击桌面后输入；Ctrl+Alt+Enter 退出直控。', 'ready');
  }
  if (state.externalKeyboard) {
    return new RemoteInteractionFeedback(inputModeLabel(state.mode) + ' · 可操作', '外接键盘直控已开启；Ctrl+Alt+Enter 退出直控。', 'ready');
  }
  return new RemoteInteractionFeedback(inputModeLabel(state.mode) + ' · 可操作', '已就绪，可直接操作桌面；点菜单调整操作方式。', 'ready');
}
