import { UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { detached } from '../pages/DetachedCoordinator';
import { WindowPolicy } from '../pages/WindowPolicy';
export default class DetachedViewAbility extends UIAbility {
    private lease: string = '';
    private main: window.Window | undefined = undefined;
    private policy: WindowPolicy = new WindowPolicy();
    private ended: boolean = false;
    onCreate(want: Want): void { const value = want.parameters?.lease; this.lease = typeof value === 'string' ? value : ''; }
    private close = async (): Promise<boolean> => { try {
        await detached.close(this.lease);
    }
    catch (_) { } return true; };
    onWindowStageCreate(stage: window.WindowStage): void {
        if (!detached.lookup(this.lease)) {
            this.context.terminateSelf();
            return;
        }
        this.policy.attach(stage, this.context);
        detached.setPolicy(this.lease, this.policy);
        this.policy.setScreenForeground(true);
        this.main = stage.getMainWindowSync();
        this.main.on('windowWillClose', this.close);
        stage.on('windowStageEvent', (event: window.WindowStageEventType) => { if (event === window.WindowStageEventType.INACTIVE) {
            detached.focus(this.lease, false);
        }
        else if (event === window.WindowStageEventType.ACTIVE) {
            try {
                detached.focus(this.lease, this.main?.isFocused() === true);
            }
            catch (_) {
                detached.focus(this.lease, false);
            }
        } });
        const storage = new LocalStorage();
        storage.setOrCreate('detachedLease', this.lease);
        stage.loadContent('pages/DetachedView', storage).catch(() => this.context.terminateSelf());
    }
    onConfigurationUpdate(_configuration:Configuration):void{this.policy.refreshSystemBars();}
    onForeground(): void { this.policy.setScreenForeground(true); try {
        detached.focus(this.lease, this.main?.isFocused() === true);
    }
    catch (_) {
        detached.focus(this.lease, false);
    } }
    onBackground(): void { this.policy.setScreenForeground(false); detached.focus(this.lease, false); }
    onWindowStageDestroy(): void { detached.focus(this.lease, false); detached.clearPolicy(this.policy); this.policy.detach(); }
    onDestroy(): void { if (!this.ended) {
        this.ended = true;
        detached.close(this.lease).catch(() => { });
    } this.policy.detach(); }
}
