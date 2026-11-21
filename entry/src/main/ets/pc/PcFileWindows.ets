import { display, window } from '@kit.ArkUI';

export interface PcFileRoute {
  deviceKey: string;
  deviceName: string;
  borrowed: boolean;
}

class PcFileWindows {
  private stage: window.WindowStage | undefined = undefined;
  private child: window.Window | undefined = undefined;
  private opening: boolean = false;
  private revision: number = 0;
  route: PcFileRoute | undefined = undefined;

  attach(stage: window.WindowStage): void { this.stage = stage; }

  detach(): void {
    this.revision++;
    this.stage = undefined;
    this.close();
  }

  async open(route: PcFileRoute): Promise<void> {
    const stage = this.stage;
    if (!stage || this.opening) { throw new Error('pc_file_window_unavailable'); }
    if (this.child) {
      if (this.route?.deviceKey !== route.deviceKey || this.route?.borrowed !== route.borrowed) {
        throw new Error('pc_file_window_in_use');
      }
      await this.child.raiseToAppTop();
      return;
    }
    this.opening = true;
    const revision = ++this.revision;
    let child: window.Window | undefined = undefined;
    try {
      child = await stage.createSubWindowWithOptions('UUHarmonyFiles', {
        title: 'UUHarmony 文件传输', decorEnabled: true, maximizeSupported: true
      });
      if (revision !== this.revision) { await child.destroyWindow(); return; }
      this.child = child;
      this.route = route;
      const current = child;
      child.on('subWindowClose', () => {
        if (this.child === current) { this.child = undefined; this.route = undefined; }
      });
      try {
        const displayInfo = display.getDefaultDisplaySync();
        const density = displayInfo.densityPixels;
        const width = Math.round(Math.min(displayInfo.width * 0.86, density * 1140));
        const height = Math.round(Math.min(displayInfo.height * 0.76, density * 720));
        await child.setWindowLimits({ minWidth: Math.min(width, Math.round(650 * density)),
          minHeight: Math.min(height, Math.round(460 * density)), maxWidth: displayInfo.width, maxHeight: displayInfo.height });
        await child.resize(width, height);
      } catch (_) {}
      await child.loadContent('pages/PcFileWindow');
      if (revision === this.revision) { await child.showWindow(); }
    } catch (error) {
      if (this.child === child) { this.child = undefined; this.route = undefined; }
      if (child) { await child.destroyWindow().catch(() => {}); }
      throw new Error('pc_file_window_open_failed');
    } finally {
      this.opening = false;
    }
  }

  close(): void {
    this.revision++;
    const child = this.child;
    this.child = undefined;
    this.route = undefined;
    child?.destroyWindow().catch(() => {});
  }
}

export const pcFileWindows = new PcFileWindows();
