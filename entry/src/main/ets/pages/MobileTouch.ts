// Pure TypeScript; this module stays within the strict ArkTS language subset.
// Coordinates/pan match the viewport's touch units. UI owns timers and surface.
export enum TouchMode {
  Direct = 'direct',
  Trackpad = 'trackpad',
  VirtualMouse = 'virtualMouse',
  Tablet = 'tablet'
}

export enum TouchEventKind {
  Down = 'down',
  Move = 'move',
  Up = 'up',
  Cancel = 'cancel'
}

export enum TouchActionKind {
  MoveAbsolute = 'moveAbsolute',
  MoveRelative = 'moveRelative',
  Press = 'press',
  Release = 'release',
  Scroll = 'scroll'
}

export enum TouchButton {
  Left = 'left',
  Right = 'right'
}

export interface TouchPoint {
  id: number;
  x: number;
  y: number;
}

export interface TouchGeometry {
  viewportW: number;
  viewportH: number;
  frameW: number;
  frameH: number;
}

export class TouchView {
  zoom: number = 1;
  panX: number = 0;
  panY: number = 0;
}

export class TouchPosition {
  x: number = 0;
  y: number = 0;
  inside: boolean = false;
}

// Fixed fields avoid structural unions/dynamic properties. MoveAbsolute x/y are
// normalized 0..1. MoveRelative dx/dy are pixels after speed scaling. Scroll dx/dy
// are finger displacement (positive dy = wheel-up); UI converts to wire units,
// one notch = 120, retaining fractions. Logical buttons map Left=1, Right=2.
export class TouchAction {
  kind: TouchActionKind;
  x: number = 0;
  y: number = 0;
  dx: number = 0;
  dy: number = 0;
  button: TouchButton = TouchButton.Left;

  constructor(kind: TouchActionKind) {
    this.kind = kind;
  }
}

enum GesturePhase {
  Idle,
  Single,
  Multi,
  Suppressed
}

export class MobileTouch {
  private onAction: (action: TouchAction) => void;
  private onView: (view: TouchView) => void;
  private mode: TouchMode = TouchMode.Direct;
  private viewOnly: boolean = false;
  private speed: number = 1;
  private viewportW: number = 0;
  private viewportH: number = 0;
  private frameW: number = 0;
  private frameH: number = 0;
  private zoom: number = 1;
  private panX: number = 0;
  private panY: number = 0;
  private phase: GesturePhase = GesturePhase.Idle;
  private points: TouchPoint[] = [];
  private start: TouchPoint = { id: -1, x: 0, y: 0 };
  private previous: TouchPoint = { id: -1, x: 0, y: 0 };
  private startTime: number = 0;
  private lastTime: number = -1;
  private tapPossible: boolean = false;
  private longPossible: boolean = false;
  private longReady: boolean = false;
  private dragging: boolean = false;
  private buttonDown: boolean = false;
  private heldButton: TouchButton = TouchButton.Left;
  private multiA: TouchPoint = { id: -1, x: 0, y: 0 };
  private multiB: TouchPoint = { id: -1, x: 0, y: 0 };
  private multiTap: boolean = false;
  private multiDropped: boolean = false;
  private scrolling: boolean = false;
  private multiLastX: number = 0;
  private multiLastY: number = 0;
  private multiStartX: number = 0;
  private multiStartY: number = 0;
  private multiDistance: number = 0;
  private multiZoom: number = 1;
  private multiPanX: number = 0;
  private multiPanY: number = 0;
  private readonly tapMs: number = 350;
  private readonly longMs: number = 550;
  private readonly slop: number = 10;
  private readonly scrollSlop: number = 8;
  private readonly maxZoom: number = 4;

  constructor(onAction: (action: TouchAction) => void, onView: (view: TouchView) => void) {
    this.onAction = onAction;
    this.onView = onView;
  }

  setMode(mode: TouchMode): void {
    if (mode !== this.mode) {
      this.cancel();
      this.mode = mode;
    }
  }

  setViewOnly(enabled: boolean): void {
    if (enabled !== this.viewOnly) {
      this.cancel();
      this.viewOnly = enabled;
    }
  }

  setSpeed(speed: number): void {
    if (Number.isFinite(speed)) {
      this.speed = this.clamp(speed, 0.25, 4);
    }
  }

  setGeometry(geometry: TouchGeometry): void {
    let vw: number = this.dimension(geometry.viewportW);
    let vh: number = this.dimension(geometry.viewportH);
    let fw: number = this.dimension(geometry.frameW);
    let fh: number = this.dimension(geometry.frameH);
    if (vw === this.viewportW && vh === this.viewportH && fw === this.frameW && fh === this.frameH) {
      return;
    }
    this.cancel();
    this.viewportW = vw;
    this.viewportH = vh;
    this.frameW = fw;
    this.frameH = fh;
    this.applyView(this.zoom, this.panX, this.panY);
  }

  setView(zoom: number, panX: number, panY: number): void {
    if (!Number.isFinite(zoom) || !Number.isFinite(panX) || !Number.isFinite(panY)) {
      return;
    }
    this.cancel();
    this.applyView(zoom, panX, panY);
  }

  resetView(): void {
    this.setView(1, 0, 0);
  }

  getView(): TouchView {
    let result: TouchView = new TouchView();
    result.zoom = this.zoom;
    result.panX = this.panX;
    result.panY = this.panY;
    return result;
  }

  // Inverse of centered fit, scaled around the center then translated.
  // Ignore contacts beginning in letterboxes; clamp established drags at edges.
  mapPoint(x: number, y: number): TouchPosition {
    let result: TouchPosition = new TouchPosition();
    if (!this.validGeometry() || !Number.isFinite(x) || !Number.isFinite(y)) {
      return result;
    }
    let scale: number = Math.min(this.viewportW / this.frameW, this.viewportH / this.frameH);
    let width: number = this.frameW * scale * this.zoom;
    let height: number = this.frameH * scale * this.zoom;
    let left: number = (this.viewportW - width) / 2 + this.panX;
    let top: number = (this.viewportH - height) / 2 + this.panY;
    result.inside = x >= 0 && x <= this.viewportW && y >= 0 && y <= this.viewportH &&
      x >= left && x <= left + width && y >= top && y <= top + height;
    result.x = this.clamp((x - left) / width, 0, 1);
    result.y = this.clamp((y - top) / height, 0, 1);
    return result;
  }

  // down/move: points = all active contacts, in any ID order.
  // up: points = ended contacts; remaining = authoritative active set AFTER up.
  // cancel ignores arrays. now = caller-supplied monotonic milliseconds.
  handle(kind: TouchEventKind, points: TouchPoint[], remaining: TouchPoint[], now: number): void {
    if (kind === TouchEventKind.Cancel) {
      this.cancel();
      return;
    }
    if (!this.validTime(now) || !this.validPoints(points) || !this.validPoints(remaining)) {
      this.cancel();
      return;
    }
    this.lastTime = now;
    if (kind === TouchEventKind.Up) {
      this.up(points, remaining, now);
      return;
    }
    if (points.length === 0) {
      this.cancel();
      return;
    }
    if (kind === TouchEventKind.Down) {
      this.down(points, now);
    } else if (kind === TouchEventKind.Move) {
      this.move(points, now);
    }
  }

  // A stationary hold stays unpressed. Its up may issue a right click, while
  // movement after the deadline starts a left drag before the movement action.
  tick(now: number): void {
    if (!this.validTime(now)) {
      this.cancel();
      return;
    }
    if (this.phase === GesturePhase.Idle) {
      return;
    }
    this.lastTime = now;
    if (this.phase === GesturePhase.Single && this.longPossible && now - this.startTime >= this.longMs) {
      this.longReady = true;
    }
  }

  cancel(): void {
    this.releaseHeld();
    this.phase = GesturePhase.Idle;
    this.points = [];
    this.tapPossible = false;
    this.longPossible = false;
    this.longReady = false;
    this.dragging = false;
    this.multiTap = false;
    this.multiDropped = false;
    this.scrolling = false;
    this.lastTime = -1;
  }

  private down(points: TouchPoint[], now: number): void {
    if (this.phase === GesturePhase.Suppressed) {
      this.points = this.copyPoints(points);
      return;
    }
    if (this.phase === GesturePhase.Idle) {
      this.startTime = now;
      this.tapPossible = true;
      this.longPossible = true;
      this.longReady = false;
      this.dragging = false;
      if (!this.validGeometry() || points.length > 2) {
        this.suppress(points);
        return;
      }
      if (points.length === 2) {
        this.beginMulti(points);
        return;
      }
      this.start = this.copyPoint(points[0]);
      this.previous = this.copyPoint(points[0]);
      this.points = this.copyPoints(points);
      if (!this.viewOnly && this.mode === TouchMode.Direct) {
        if (!this.mapPoint(this.start.x, this.start.y).inside) {
          this.suppress(points);
          return;
        }
        this.emitAbsolute(this.start);
      }
      this.phase = GesturePhase.Single;
      return;
    }
    if (this.phase === GesturePhase.Single && points.length === 2 && this.findPoint(points, this.start.id) !== undefined) {
      this.beginMulti(points);
    } else if (this.phase === GesturePhase.Single && points.length === 1 && points[0].id === this.start.id) {
      this.points = this.copyPoints(points);
    } else {
      this.suppress(points);
    }
  }

  private move(points: TouchPoint[], now: number): void {
    if (this.phase === GesturePhase.Single) {
      if (points.length !== 1 || points[0].id !== this.start.id) {
        this.suppress(points);
        return;
      }
      this.moveSingle(points[0], now, true);
    } else if (this.phase === GesturePhase.Multi) {
      this.moveMulti(points);
    }
    this.points = this.copyPoints(points);
  }

  private up(ended: TouchPoint[], remaining: TouchPoint[], now: number): void {
    if (this.phase === GesturePhase.Idle) {
      return;
    }
    for (let i: number = 0; i < ended.length; i++) {
      if (this.findPoint(remaining, ended[i].id) !== undefined) {
        this.cancel();
        return;
      }
    }
    if (this.phase === GesturePhase.Single) {
      let stillDown: TouchPoint | undefined = this.findPoint(remaining, this.start.id);
      if (stillDown !== undefined && remaining.length === 1) {
        this.points = this.copyPoints(remaining);
        return;
      }
      if (remaining.length > 0) {
        this.suppress(remaining);
        return;
      }
      let finalPoint: TouchPoint | undefined = this.findPoint(ended, this.start.id);
      if (finalPoint !== undefined) {
        this.moveSingle(finalPoint, now, false);
      }
      if (!this.viewOnly) {
        if (this.dragging) {
          this.releaseHeld();
        } else if (this.longPossible && now - this.startTime >= this.longMs) {
          this.click(TouchButton.Right);
        } else if (this.tapPossible && now - this.startTime <= this.tapMs) {
          this.click(TouchButton.Left);
        }
      }
    } else if (this.phase === GesturePhase.Multi) {
      this.markMultiMotion(ended);
      this.markMultiMotion(remaining);
      if (remaining.length > 1) {
        this.suppress(remaining);
        return;
      }
      if (remaining.length === 1) {
        if (remaining[0].id !== this.multiA.id && remaining[0].id !== this.multiB.id) {
          this.suppress(remaining);
          return;
        }
        this.multiDropped = true;
      } else if (!this.viewOnly && this.multiTap && now - this.startTime <= this.tapMs) {
        this.click(TouchButton.Right);
      }
    }
    this.points = this.copyPoints(remaining);
    if (remaining.length === 0) {
      this.cancel();
    }
  }

  private moveSingle(point: TouchPoint, now: number, allowDrag: boolean): void {
    let dx: number = point.x - this.previous.x;
    let dy: number = point.y - this.previous.y;
    let distance: number = this.distance(point, this.start);
    if (distance > this.slop) {
      this.tapPossible = false;
      if (this.longPossible && (this.longReady || now - this.startTime >= this.longMs) && allowDrag && !this.viewOnly) {
        this.press(TouchButton.Left);
        this.dragging = true;
      }
      this.longPossible = false;
    }
    if (!this.viewOnly && (dx !== 0 || dy !== 0)) {
      if (this.mode === TouchMode.Direct) {
        this.emitAbsolute(point);
      } else {
        let action: TouchAction = new TouchAction(TouchActionKind.MoveRelative);
        action.dx = dx * this.speed;
        action.dy = dy * this.speed;
        this.onAction(action);
      }
    }
    this.previous = this.copyPoint(point);
  }

  private beginMulti(points: TouchPoint[]): void {
    let wasDragging: boolean = this.dragging;
    this.releaseHeld();
    this.dragging = false;
    this.phase = GesturePhase.Multi;
    this.multiA = this.copyPoint(points[0]);
    this.multiB = this.copyPoint(points[1]);
    this.multiTap = this.mode === TouchMode.Trackpad && this.tapPossible && !wasDragging;
    this.multiDropped = false;
    this.scrolling = false;
    this.multiStartX = (points[0].x + points[1].x) / 2;
    this.multiStartY = (points[0].y + points[1].y) / 2;
    this.multiLastX = this.multiStartX;
    this.multiLastY = this.multiStartY;
    this.multiDistance = this.distance(points[0], points[1]);
    this.multiZoom = this.zoom;
    this.multiPanX = this.panX;
    this.multiPanY = this.panY;
    this.points = this.copyPoints(points);
  }

  private moveMulti(points: TouchPoint[]): void {
    this.markMultiMotion(points);
    if (points.length === 1 && this.multiDropped) {
      return;
    }
    if (points.length !== 2 || this.multiDropped) {
      this.suppress(points);
      return;
    }
    let a: TouchPoint | undefined = this.findPoint(points, this.multiA.id);
    let b: TouchPoint | undefined = this.findPoint(points, this.multiB.id);
    if (a === undefined || b === undefined) {
      this.suppress(points);
      return;
    }
    let x: number = (a.x + b.x) / 2;
    let y: number = (a.y + b.y) / 2;
    if (this.viewOnly) {
      if (this.multiDistance <= 0) {
        return;
      }
      let zoom: number = this.clamp(this.multiZoom * this.distance(a, b) / this.multiDistance, 1, this.maxZoom);
      let ratio: number = zoom / this.multiZoom;
      let panX: number = x - this.viewportW / 2 - (this.multiStartX - this.viewportW / 2 - this.multiPanX) * ratio;
      let panY: number = y - this.viewportH / 2 - (this.multiStartY - this.viewportH / 2 - this.multiPanY) * ratio;
      this.applyView(zoom, panX, panY);
    } else {
      // Both remote-control modes use two fingers for scrolling. Only the
      // explicit view-only mode above may turn those contacts into zoom/pan.
      let dx: number = x - this.multiLastX;
      let dy: number = y - this.multiLastY;
      if (!this.scrolling && Math.sqrt(dx * dx + dy * dy) < this.scrollSlop) {
        return;
      }
      this.scrolling = true;
      this.multiTap = false;
      if (dx !== 0 || dy !== 0) {
        let action: TouchAction = new TouchAction(TouchActionKind.Scroll);
        action.dx = dx;
        action.dy = dy;
        this.onAction(action);
      }
      this.multiLastX = x;
      this.multiLastY = y;
    }
  }

  private markMultiMotion(points: TouchPoint[]): void {
    for (let i: number = 0; i < points.length; i++) {
      let point: TouchPoint = points[i];
      if ((point.id === this.multiA.id && this.distance(point, this.multiA) > this.slop) ||
        (point.id === this.multiB.id && this.distance(point, this.multiB) > this.slop)) {
        this.multiTap = false;
      }
    }
  }

  private emitAbsolute(point: TouchPoint): void {
    let position: TouchPosition = this.mapPoint(point.x, point.y);
    let action: TouchAction = new TouchAction(TouchActionKind.MoveAbsolute);
    action.x = position.x;
    action.y = position.y;
    this.onAction(action);
  }

  private click(button: TouchButton): void {
    this.press(button);
    this.releaseHeld();
  }

  private press(button: TouchButton): void {
    if (this.buttonDown) {
      return;
    }
    this.buttonDown = true;
    this.heldButton = button;
    let action: TouchAction = new TouchAction(TouchActionKind.Press);
    action.button = button;
    this.onAction(action);
  }

  private releaseHeld(): void {
    if (!this.buttonDown) {
      return;
    }
    this.buttonDown = false;
    let action: TouchAction = new TouchAction(TouchActionKind.Release);
    action.button = this.heldButton;
    this.onAction(action);
  }

  private suppress(points: TouchPoint[]): void {
    this.releaseHeld();
    this.dragging = false;
    this.tapPossible = false;
    this.longPossible = false;
    this.multiTap = false;
    this.phase = GesturePhase.Suppressed;
    this.points = this.copyPoints(points);
  }

  private applyView(zoom: number, panX: number, panY: number): void {
    let nextZoom: number = this.clamp(zoom, 1, this.maxZoom);
    let maxX: number = 0;
    let maxY: number = 0;
    if (this.validGeometry()) {
      let fit: number = Math.min(this.viewportW / this.frameW, this.viewportH / this.frameH);
      maxX = Math.max(0, (this.frameW * fit * nextZoom - this.viewportW) / 2);
      maxY = Math.max(0, (this.frameH * fit * nextZoom - this.viewportH) / 2);
    }
    let nextX: number = this.clamp(panX, -maxX, maxX);
    let nextY: number = this.clamp(panY, -maxY, maxY);
    if (nextZoom !== this.zoom || nextX !== this.panX || nextY !== this.panY) {
      this.zoom = nextZoom;
      this.panX = nextX;
      this.panY = nextY;
      this.onView(this.getView());
    }
  }

  private validGeometry(): boolean {
    return this.viewportW > 0 && this.viewportH > 0 && this.frameW > 0 && this.frameH > 0;
  }

  private validTime(now: number): boolean {
    return Number.isFinite(now) && now >= 0 && (this.lastTime < 0 || now >= this.lastTime);
  }

  private validPoints(points: TouchPoint[]): boolean {
    for (let i: number = 0; i < points.length; i++) {
      let point: TouchPoint = points[i];
      if (!Number.isFinite(point.id) || Math.floor(point.id) !== point.id || point.id < 0 ||
        !Number.isFinite(point.x) || !Number.isFinite(point.y)) {
        return false;
      }
      for (let j: number = 0; j < i; j++) {
        if (points[j].id === point.id) {
          return false;
        }
      }
    }
    return true;
  }

  private findPoint(points: TouchPoint[], id: number): TouchPoint | undefined {
    for (let i: number = 0; i < points.length; i++) {
      if (points[i].id === id) {
        return points[i];
      }
    }
    return undefined;
  }

  private copyPoint(point: TouchPoint): TouchPoint {
    let result: TouchPoint = { id: point.id, x: point.x, y: point.y };
    return result;
  }

  private copyPoints(points: TouchPoint[]): TouchPoint[] {
    let result: TouchPoint[] = [];
    for (let i: number = 0; i < points.length; i++) {
      result.push(this.copyPoint(points[i]));
    }
    return result;
  }

  private distance(a: TouchPoint, b: TouchPoint): number {
    let dx: number = a.x - b.x;
    let dy: number = a.y - b.y;
    return Math.sqrt(dx * dx + dy * dy);
  }

  private dimension(value: number): number {
    return Number.isFinite(value) && value > 0 ? value : 0;
  }

  private clamp(value: number, low: number, high: number): number {
    return Math.max(low, Math.min(high, value));
  }
}
