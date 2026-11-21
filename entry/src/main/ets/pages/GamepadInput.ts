import { RemoteInput } from './MobileInput';

// Harmony key codes mapped to the Windows gamepad button mask.
const masks = new Map<number, number>([
  [2012, 1], [2013, 2], [2014, 4], [2015, 8], [2312, 16], [2311, 32],
  [2314, 64], [2315, 128], [2307, 256], [2308, 512],
  [2301, 4096], [2302, 8192], [2304, 16384], [2305, 32768]
]);
function stick(value:number):number {
  const bounded = Math.max(-1, Math.min(1, value));
  return Math.round(bounded * (bounded < 0 ? 32768 : 32767));
}

export class GamepadInput {
  device = -1;
  private buttons = 0;
  private digitalTriggers = 0;
  private axes: number[] = new Array<number>(8).fill(0);
  private attached = false;
  private dirty = false;
  constructor(private sink:(events:RemoteInput[])=>boolean) {}

  reset():void {
    this.device = -1;
    this.attached = false;
    this.dirty = false;
    this.buttons = 0;
    this.digitalTriggers = 0;
    this.axes.fill(0);
  }
  private select(id:number):boolean {
    if (!Number.isInteger(id) || id < 0 || (this.device >= 0 && id !== this.device)) { return false; }
    this.device = id;
    return true;
  }
  key(id:number, code:number, down:boolean):boolean {
    const mask = masks.get(code) || 0;
    const trigger = code === 2309 ? 1 : code === 2310 ? 2 : 0;
    if (!(mask || trigger) || !this.select(id)) { return false; }
    const next = down ? this.buttons | mask : this.buttons & ~mask;
    const nextTriggers = down ? this.digitalTriggers | trigger : this.digitalTriggers & ~trigger;
    if (next !== this.buttons || nextTriggers !== this.digitalTriggers) {
      this.buttons = next;
      this.digitalTriggers = nextTriggers;
      this.dirty = true;
      this.flush(); // Keep press and release in order, even within one video frame.
    }
    return true;
  }
  axis(id:number, index:number, value:number):void {
    if (!Number.isInteger(index) || index < 0 || index > 7 || !Number.isFinite(value) ||
        !this.select(id)) { return; }
    const normalized = Math.max(-1, Math.min(1, value));
    if (this.axes[index] !== normalized) { this.axes[index] = normalized; this.dirty = true; }
  }
  flush():void {
    if (!this.dirty || this.device < 0) { return; }
    const hatX = this.axes[6], hatY = this.axes[7];
    const horizontal = hatX < -0.5 ? 4 : hatX > 0.5 ? 8 : 0;
    const vertical = hatY < -0.5 ? 1 : hatY > 0.5 ? 2 : 0;
    const packet:RemoteInput = {
      action:'gpd_update', index:0, buttons:this.buttons | horizontal | vertical,
      left_thumb_x:stick(this.axes[0]), left_thumb_y:stick(-this.axes[1]),
      right_thumb_x:stick(this.axes[2]), right_thumb_y:stick(-this.axes[3]),
      left_trigger:(this.digitalTriggers & 1) ? 255 : Math.round(255*Math.max(0,this.axes[5])),
      right_trigger:(this.digitalTriggers & 2) ? 255 : Math.round(255*Math.max(0,this.axes[4]))
    };
    const events:RemoteInput[] = [];
    if (!this.attached) { events.push({action:'gpd_connect',index:0}); }
    events.push(packet);
    if (this.sink(events)) { this.attached = true; this.dirty = false; }
  }
}
