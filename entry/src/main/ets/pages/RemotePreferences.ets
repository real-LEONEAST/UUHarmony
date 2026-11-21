import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { TouchMode } from './MobileTouch';
import { RemoteInputPreferences, normalizeInputPreferences } from './RemoteInteractionModel';

// Only local mode and speed are persisted. Capture, watch and account state are not.
export class RemotePreferences {
  available: boolean = true;
  private context: common.Context;
  private store: preferences.Preferences | undefined = undefined;
  private tail: Promise<boolean> = Promise.resolve(true);

  constructor(context: common.Context) {
    this.context = context;
  }

  private getStore(): preferences.Preferences {
    if (!this.store) {
      this.store = preferences.getPreferencesSync(this.context, { name: 'remote_interaction_v1' });
    }
    return this.store;
  }

  load(): RemoteInputPreferences {
    try {
      const store = this.getStore();
      const mode = store.getSync('mode', TouchMode.Direct);
      const speed = store.getSync('speed', 1);
      const value = normalizeInputPreferences(typeof mode === 'string' ? mode : TouchMode.Direct, typeof speed === 'number' ? speed : 1);
      const size=store.getSync('mouseSize',1); const opacity=store.getSync('mouseOpacity',0.8);
      const x=store.getSync('mouseX',20); const y=store.getSync('mouseY',30);
      value.mouseSize=typeof size==='number'&&Number.isFinite(size)?Math.max(0.8,Math.min(1.4,size)):1;
      value.mouseOpacity=typeof opacity==='number'&&Number.isFinite(opacity)?Math.max(0.4,Math.min(1,opacity)):0.8;
      value.mouseX=typeof x==='number'&&Number.isFinite(x)?Math.max(0,x):20;
      value.mouseY=typeof y==='number'&&Number.isFinite(y)?Math.max(0,y):30;
      this.available = true; return value;
    } catch (_) {
      this.available = false;
      return new RemoteInputPreferences();
    }
  }

  loadVideoCodec():number {
    try { const store=this.getStore();if(store.getSync('videoCodecPolicy',0)!==2){return 0;}return store.getSync('videoCodec',0)===1?1:0; } catch (_) { return 0; }
  }
  saveVideoCodec(value:number):Promise<boolean> {
    const selected=value===1?1:0;
    const next=this.tail.then(async()=>{try{const store=this.getStore();store.putSync('videoCodec',selected);store.putSync('videoCodecPolicy',2);await store.flush();return true;}catch(_){return false;}});
    this.tail=next;return next;
  }
  loadExternalKeyboard(defaultValue:boolean):boolean {
    try {const value=this.getStore().getSync('externalKeyboard',defaultValue);return typeof value==='boolean'?value:defaultValue;} catch (_) {return defaultValue;}
  }
  saveExternalKeyboard(value:boolean):Promise<boolean> {
    const next=this.tail.then(async()=>{try{const store=this.getStore();store.putSync('externalKeyboard',value);await store.flush();return true;}catch(_){return false;}});
    this.tail=next;return next;
  }

  save(mode: TouchMode, speed: number, size: number = 1, opacity: number = 0.8, x: number = 20, y: number = 30): Promise<boolean> {
    const value = normalizeInputPreferences(mode, speed);
    value.mouseSize=size; value.mouseOpacity=opacity; value.mouseX=x; value.mouseY=y;
    const next = this.tail.then(() => this.write(value));
    this.tail = next;
    return next;
  }

  private async write(value: RemoteInputPreferences): Promise<boolean> {
    try {
      const store = this.getStore();
      store.putSync('mode', value.mode);
      store.putSync('speed', value.speed);
      store.putSync('mouseSize',value.mouseSize); store.putSync('mouseOpacity',value.mouseOpacity);
      store.putSync('mouseX',value.mouseX); store.putSync('mouseY',value.mouseY);
      await store.flush();
      this.available = true;
      return true;
    } catch (_) {
      this.available = false;
      return false;
    }
  }
}
