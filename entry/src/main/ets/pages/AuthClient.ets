import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { invoke } from 'libs3c.so';

import { DeviceRow } from './DeviceListModel';
import { LocalDeviceProfile } from './LocalDeviceProfile';
import { validatedLocalName } from './LocalNameModel';
export interface AuthView { registeredIdentity?:boolean; manualNameStatus?:string; deviceRemovalStatus?:string; nameSyncStatus?:string; deviceMigration?:string; migrationDiagnostic?:string; migrationValidation?:string; migrationReadback?:number; migrationHttp?:number; migrationApi?:number; wallpaperAccountKey?:string; state: string; message: string; loggedIn: boolean; accountLabel: string; qr: string; devices: DeviceRow[]; devicesUpdatedAtMs: number; devicesRefreshFailed: boolean; devicesIncomplete: number; refreshes: number; httpStatus: number; apiCode: number; pending: boolean; suspended: boolean; canResume: boolean; qrExpiresAtMs: number; qrPersistence: string; qrExportAllowed: boolean; smsSupported: boolean; sameDeviceDeepLinkSupported: boolean; }
interface WireRequest { id: number; kind: string; url: string; method: string; headers: Record<string, string>; body: string; timeoutMs: number; }
interface Envelope { view: AuthView; request: WireRequest | null; qrExport?: string; }
interface Command { op: string; id?: number; httpStatus?: number; body?: string; timeout?: boolean; confirmed?: boolean; name?:string; deviceKey?:string; participantToken?:string; deviceProfile?:LocalDeviceProfile; }
export function emptyView(): AuthView { return { state: 'starting', message: '初始化系统安全存储…', loggedIn: false, accountLabel: '', qr: '', devices: [], devicesUpdatedAtMs: 0, devicesRefreshFailed: false, devicesIncomplete: 0, refreshes: 0, httpStatus: 0, apiCode: 0, pending: false, suspended: false, canResume: false, qrExpiresAtMs: 0, qrPersistence: 'none', qrExportAllowed: false, smsSupported: false, sameDeviceDeepLinkSupported: false }; }

class AuthClient {
  private profile:LocalDeviceProfile|undefined=undefined;
  private profileProvider:(()=>LocalDeviceProfile)|undefined=undefined;
  setDeviceProfileProvider(provider:()=>LocalDeviceProfile):void{this.profileProvider=provider;this.setDeviceProfile(provider());}
  private profileForRefresh():LocalDeviceProfile|undefined{try{if(this.profileProvider){this.setDeviceProfile(this.profileProvider());}}catch(_){}return this.profile;}
  setDeviceProfile(profile:LocalDeviceProfile):void{
    this.profile=profile;
    hilog.info(0x0303,'UUS3C','local_device_profile lengths name=%{public}d os=%{public}d cpu=%{public}d model=%{public}d screen=%{public}d',profile.name.length,profile.os.length,profile.cpu.length,profile.model.length,profile.screen.length);
  }
  private epoch: number = 0;
  private active: http.HttpRequest | undefined = undefined;
  private timer: number = -1;
  private wake: (() => void) | undefined = undefined;
  private observer: ((v: AuthView) => void) | undefined = undefined;
  private monitors: Map<number,(v:AuthView)=>void> = new Map();
  private nextMonitor:number=0;
  private beforeLoad:(()=>Promise<void>)|undefined=undefined;
  private registrationStore:preferences.Preferences|undefined=undefined;
  private expectRegisteredIdentity:boolean=false;
  private registrationSaved:boolean=false;
  setRegistrationStore(context:common.UIAbilityContext):void {
    if(this.registrationStore){return;}
    try {
      const store=preferences.getPreferencesSync(context,{name:'uu.auth.continuity'});
      this.expectRegisteredIdentity=store.getSync('registered',false)===true;
      this.registrationSaved=this.expectRegisteredIdentity;
      this.registrationStore=store;
    } catch (_) {
      hilog.warn(0x0303,'UUS3C','registration_marker_read_failed');
    }
  }
  setBeforeLoad(fn:()=>Promise<void>):void { if(!this.ready&&!this.booting){this.beforeLoad=fn;} }
  monitor(fn:(v:AuthView)=>void):()=>void { const id=++this.nextMonitor;this.monitors.set(id,fn);fn(this.view);return ()=>{this.monitors.delete(id);}; }
  private notifyMonitors(v:AuthView):void {this.monitors.forEach((fn:(v:AuthView)=>void)=>{fn(v);});}
  private ready: boolean = false;
  private foreground: boolean = true;
  private serial: Promise<void> = Promise.resolve();
  private booting: Promise<void> | undefined = undefined;
  private expiryTimer: number = -1;
  view: AuthView = emptyView();
  busy: boolean = false;
  private operation:Promise<void>|undefined=undefined;
  private operationEpoch:number=-1;
  observe(fn: ((v: AuthView) => void) | undefined): () => void {
    this.observer = fn;
    if (fn) { fn(this.view); }
    return () => { if (this.observer === fn) { this.observer = undefined; } };
  }
  private show(v: AuthView): void {
    this.view = v;
    this.armExpiry(v);
    this.notifyMonitors(v);
    if (this.observer) { this.observer(v); }
    const safeNameStatus:string[]=['waiting_list','attempted','not_pc','missing_identity','name_unavailable','own_row_not_unique','invalid_alias','cloud_name_conflict','cloud_name_missing','reported_name_missing','local_name_missing','owner_mismatch','already_current','cloud_name_changed','sending','accepted','failed','network_error','cloud_row_conflict'];
    if(v.nameSyncStatus&&safeNameStatus.includes(v.nameSyncStatus)){hilog.info(0x0303,'UUS3C','name_sync=%{public}s',v.nameSyncStatus);}
    if(v.migrationDiagnostic&&v.migrationDiagnostic!=='pending'){hilog.info(0x0303,'UUS3C','migration outcome=%{public}s http=%{public}d api=%{public}d',v.migrationDiagnostic,v.migrationHttp||0,v.migrationApi??-1);if(v.migrationValidation){hilog.info(0x0303,'UUS3C','migration validation=%{public}s',v.migrationValidation);}}
    if(v.deviceMigration==='success'||v.deviceMigration==='readback_unconfirmed'||v.deviceMigration==='alias_changed'){const own=v.devices.filter((d:DeviceRow)=>d.current);const raw=own.length===1?own[0].fields['platform']:undefined;hilog.info(0x0303,'UUS3C','migration status=%{public}s native_platform=%{public}d projected_platform=%{public}d',v.deviceMigration,v.migrationReadback??-1,typeof raw==='number'?raw:-1);}
    hilog.info(0x0303, 'UUS3C', 'state=%{public}s logged=%{public}d http=%{public}d api=%{public}d devices=%{public}d refreshes=%{public}d', v.state, v.loggedIn ? 1 : 0, v.httpStatus, v.apiCode, v.devices.length, v.refreshes);
  }
  // Async NAPI workers can run on different threads: serialize auth commands before enqueue.
  private command(c: Command): Promise<Envelope> {
    const result = this.serial.then(async ():Promise<Envelope> => {
      const envelope=JSON.parse(await invoke(JSON.stringify(c),this.expectRegisteredIdentity)) as Envelope;
      if(envelope.view.registeredIdentity){
        this.expectRegisteredIdentity=true;
        const store=this.registrationStore;
        if(store&&!this.registrationSaved){
          try {store.putSync('registered',true);await store.flush();this.registrationSaved=true;}
          catch (_) {hilog.warn(0x0303,'UUS3C','registration_marker_write_failed');}
        }
      }
      return envelope;
    });
    this.serial = result.then((): void => {}, (): void => {});
    return result;
  }
  async boot(): Promise<void> {
    if (this.ready) { return; }
    if (!this.booting) { this.booting = this.load(); }
    try { await this.booting; } finally { this.booting = undefined; }
  }
  private async load(): Promise<void> {
    const run = this.epoch;
    try {
      if(this.beforeLoad){await this.beforeLoad();}
      let e = await this.command({ op: 'boot',deviceProfile:this.profile }); this.ready = true;
      if (!this.foreground) { e = await this.command({ op: 'suspend' }); }
      if (run === this.epoch) { this.show(e.view); }
    } catch (_) { this.storageError(); }
  }
  private armExpiry(v: AuthView): void {
    if (this.expiryTimer >= 0) { clearTimeout(this.expiryTimer); this.expiryTimer = -1; }
    if (!this.foreground || !v.canResume || v.qrExpiresAtMs <= 0) { return; }
    this.expiryTimer = setTimeout(() => { this.expiryTimer = -1; this.expire(); }, Math.max(1, v.qrExpiresAtMs - Date.now()));
  }
  private async expire(): Promise<void> {
    const run = ++this.epoch; this.release(); this.busy = false;
    try { const e = await this.command({ op: 'auth_status' }); if (run === this.epoch) { this.show(e.view); } }
    catch (_) { if (run === this.epoch) { this.storageError(); } }
  }
  private storageError(): void {
    this.ready = false; this.epoch++; this.release(); this.busy = false;
    let v = emptyView(); v.state = 'storage_error'; v.message = '暂时无法恢复原有登录或设备身份。请确认设备已解锁，再重试恢复。'; this.show(v);
  }
  private release(): void {
    if (this.active) { this.active.destroy(); this.active = undefined; }
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    if (this.expiryTimer >= 0) { clearTimeout(this.expiryTimer); this.expiryTimer = -1; }
    if (this.wake) { const fn = this.wake; this.wake = undefined; fn(); }
  }
  private async delay(ms: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => { this.wake = resolve; this.timer = setTimeout(() => { this.timer = -1; this.wake = undefined; resolve(); }, ms); });
  }
  async cancel(): Promise<void> {
    const run = ++this.epoch; this.release(); this.busy = false;
    this.view.qr = ''; this.view.canResume = false; this.view.qrExportAllowed = false;
    try { const e = await this.command({ op: 'cancel' }); if (run === this.epoch) { this.show(e.view); } }
    catch (_) { if (run === this.epoch) { this.storageError(); } }
  }
  suspend(): void {
    this.foreground = false;
    const run = ++this.epoch; this.release(); this.busy = false;
    this.view.qr = ''; this.view.suspended = true; this.view.qrExportAllowed = false;
    if (this.observer) { this.observer(this.view); }
    if(this.ready){this.pauseCore(run);}
  }
  private async pauseCore(run: number): Promise<void> {
    try { const e = await this.command({ op: 'suspend' }); if (run === this.epoch) { this.show(e.view); } }
    catch (_) { if (run === this.epoch) { this.storageError(); } }
  }
  async resume(): Promise<void> {
    this.foreground = true;
    const observed = this.epoch;
    await this.boot();
    if (observed !== this.epoch || !this.ready || !this.foreground || this.busy) { return; }
    await this.drive('resume');
  }
  async logout(): Promise<void> {
    const run = ++this.epoch; this.release(); this.busy = false;
    this.view.qr = ''; this.view.canResume = false; this.view.qrExportAllowed = false;
    try { const e = await this.command({ op: 'logout' }); if (run === this.epoch) { this.show(e.view); } }
    catch (_) { if (run === this.epoch) { this.storageError(); } }
  }
  // Explicit UI save only. The returned QR is a temporary credential; never log/share it automatically.
  async exportQr(): Promise<string> {
    if (!this.ready || !this.foreground || !this.view.qrExportAllowed) { return ''; }
    const run = this.epoch;
    try {
      const e = await this.command({ op: 'qr_export', confirmed: true });
      if (run !== this.epoch || !this.foreground || !e.view.qrExportAllowed || !this.view.qrExportAllowed || e.view.qrExpiresAtMs !== this.view.qrExpiresAtMs || Date.now() >= e.view.qrExpiresAtMs) { return ''; }
      return e.qrExport ? e.qrExport : '';
    } catch (_) { if (run === this.epoch) { this.storageError(); } return ''; }
  }
  async start(op: string): Promise<void> {
    if (op === 'resume') { await this.resume(); return; }
    if (op !== 'begin' && op !== 'refresh') { return; }
    const observed = this.epoch;
    await this.boot();
    if (observed !== this.epoch || !this.ready || !this.foreground || this.busy) { return; }
    await this.drive(op);
  }
  // Page/return/timer/connection callers share one real refresh; none cancels another.
  async refreshDevices(force:boolean=false):Promise<boolean>{
    await this.boot();
    if(!this.ready||!this.foreground||!this.view.loggedIn){return false;}
    if(this.operation&&this.operationEpoch===this.epoch){await this.operation;return this.devicesConfirmed();}
    if(this.busy||this.view.pending){return false;}
    if(!force&&this.devicesConfirmed()){return true;}
    await this.drive('refresh');return this.devicesConfirmed();
  }
  async clearDeviceControl(deviceKey:string,participantToken:string):Promise<boolean>{
    if(!this.ready||!this.foreground||this.busy||this.view.pending||!this.view.loggedIn){return false;}
    const run=++this.epoch;this.release();this.busy=true;
    try{const e=await this.command({op:'clear_device_control',deviceKey:deviceKey,participantToken:participantToken,confirmed:true});
      if(run!==this.epoch||!e.request){return false;}this.show(e.view);const result=await this.send(e.request,run);
      if(!result||run!==this.epoch){return false;}this.show(result.view);return result.view.state==='signed_in'&&result.view.httpStatus===200&&result.view.apiCode===0;
    }catch(_){return false;}finally{if(run===this.epoch){this.release();this.busy=false;}}
  }
  async removeDevice(deviceKey:string,name:string):Promise<string>{
    const account=this.view.wallpaperAccountKey||'';
    if(!this.ready||!this.foreground||!account||!await this.refreshDevices()){return 'unavailable';}
    if(this.busy||this.view.pending||!this.view.loggedIn||account!==this.view.wallpaperAccountKey){return 'unavailable';}
    const run=++this.epoch;this.release();this.busy=true;
    try{
      let e=await this.command({op:'remove_device',deviceKey:deviceKey,name:name,confirmed:true});
      if(!e.request||e.request.kind!=='unbind_preflight'){return 'unavailable';}
      while(run===this.epoch&&this.foreground&&account===this.view.wallpaperAccountKey){
        this.show(e.view);
        if(!e.request){return e.view.deviceRemovalStatus||'unconfirmed';}
        const next=await this.send(e.request,run);
        if(!next||run!==this.epoch){return 'unconfirmed';}
        e=next;
      }
      return 'unconfirmed';
    }catch(_){return 'unconfirmed';}
    finally{if(run===this.epoch){this.release();this.busy=false;}}
  }
  async renameCurrentDevice(value:string,deviceKey:string):Promise<string>{
    const name=validatedLocalName(value);if(!name){return 'invalid';}
    if(!this.ready||!this.foreground||this.busy||this.view.pending||!this.view.loggedIn){return 'unavailable';}
    const account=this.view.wallpaperAccountKey||'';if(!account){return 'unavailable';}
    await this.drive('manual_name_refresh');
    if(!this.devicesConfirmed()||!this.view.loggedIn||account!==(this.view.wallpaperAccountKey||'')||this.view.devices.filter((row:DeviceRow)=>row.current&&row.key===deviceKey).length!==1||this.view.devices.filter((row:DeviceRow)=>row.current).length!==1||this.busy||this.view.pending){return 'unavailable';}
    const run=++this.epoch;this.release();this.busy=true;
    try{let e=await this.command({op:'manual_name',name:name,deviceKey:deviceKey});let putSent:boolean=false;let readbackSent:boolean=false;
      while(run===this.epoch&&this.foreground&&account===(this.view.wallpaperAccountKey||'')){
        this.show(e.view);if(!e.request){const own=e.view.devices.filter((row:DeviceRow)=>row.current&&row.key===deviceKey);return putSent&&readbackSent&&e.view.loggedIn&&account===(e.view.wallpaperAccountKey||'')&&e.view.state==='signed_in'&&e.view.manualNameStatus==='success'&&own.length===1&&own[0].fields['alias']===name?'success':e.view.manualNameStatus==='failed'?'failed':'unconfirmed';}
        const kind=e.request.kind;const next=await this.send(e.request,run);if(!next||run!==this.epoch){return 'unconfirmed';}if(kind==='rename_manual'){putSent=true;}if(kind==='devices'&&putSent){readbackSent=true;}e=next;
      }
      return 'unconfirmed';
    }catch(_){return 'unconfirmed';}finally{if(run===this.epoch){this.release();this.busy=false;}}
  }
  private devicesConfirmed():boolean{const age=Date.now()-this.view.devicesUpdatedAtMs;return this.view.loggedIn&&!this.view.suspended&&!this.view.pending&&!this.view.devicesRefreshFailed&&this.view.devicesUpdatedAtMs>0&&age>=0&&age<45000;}
  private drive(op:string):Promise<void>{
    if(this.operation&&this.operationEpoch===this.epoch){return this.operation;}
    const task=this.execute(op);this.operation=task;this.operationEpoch=this.epoch;
    task.finally(()=>{if(this.operation===task){this.operation=undefined;}}).catch(()=>{});
    return task;
  }
  private async execute(op: string): Promise<void> {
    const run = ++this.epoch; this.release(); this.busy = true;
    try {
      let e = await this.command({ op: op,deviceProfile:op==='refresh'?this.profileForRefresh():undefined }); let listed = false;
      while (run === this.epoch && this.foreground) {
        this.show(e.view);
        if (e.request) {
          const req = e.request; if (req.kind === 'devices') { listed = true; }
          const out = await this.send(req, run);
          if (!out || run !== this.epoch || !this.foreground) { break; }
          e = out; continue;
        }
        if (e.view.state === 'waiting_scan' || e.view.state === 'scanned') {
          await this.delay(350); if (run !== this.epoch || !this.foreground) { break; }
          e = await this.command({ op: 'poll' }); continue;
        }
        if(e.view.pending){break;}
        const updated: number = e.view.devicesUpdatedAtMs || 0;
        const needsList: boolean = updated <= 0 || e.view.devicesRefreshFailed || Date.now() < updated || Date.now() - updated >= 60000;
        if (e.view.loggedIn && !listed && (op !== 'resume' || needsList)) { e = await this.command({ op: 'refresh',deviceProfile:this.profileForRefresh() }); continue; }
        break;
      }
    } catch (_) { if (run === this.epoch) { this.storageError(); } }
    finally { if (run === this.epoch) { this.release(); this.busy = false; this.armExpiry(this.view); if (this.observer) { this.observer(this.view); } } }
  }
  private async send(req: WireRequest, run: number): Promise<Envelope | undefined> {
    // Signed body is sent verbatim. In particular gen/login is an empty POST, not {}.
    if (run !== this.epoch || !this.foreground) { return undefined; }
    if ((req.kind === 'poll' || req.kind === 'exchange') && Date.now() >= this.view.qrExpiresAtMs) { await this.expire(); return undefined; }
    const task = http.createHttp(); this.active = task;
    const started = Date.now();
    let deadline: number = -1;
    let deadlineExpired: boolean = false;
    try {
      let options: http.HttpRequestOptions = { method: req.method === 'GET' ? http.RequestMethod.GET : req.method === 'PUT' ? http.RequestMethod.PUT : http.RequestMethod.POST, header: req.headers, expectDataType: http.HttpDataType.STRING, connectTimeout: 12000, readTimeout: req.timeoutMs, usingCache: false };
      if (req.body.length > 0) { options.extraData = req.body; }
      const pending = task.request(req.url, options);
      const response = (req.kind === 'devices'||req.kind === 'unbind_preflight'||req.kind === 'unbind_device') ? await Promise.race([pending, new Promise<http.HttpResponse>((resolve, reject) => {
        deadline = setTimeout(() => { deadlineExpired = true; reject(new Error('device_request_deadline')); try { task.destroy(); } catch (_) {} }, 25000);
      })]) : await pending;
      if (run !== this.epoch) { return undefined; }
      hilog.info(0x0303, 'UUS3C', 'request=%{public}s http=%{public}d elapsed_ms=%{public}d', req.kind, response.responseCode, Date.now() - started);
      const body = typeof response.result === 'string' ? response.result : '';
      if (body.length > 1048576) { return await this.command({ op: 'network_error', id: req.id, timeout: false }); }
      return await this.command({ op: 'response', id: req.id, httpStatus: response.responseCode, body: body });
    } catch (error) {
      if (run !== this.epoch) { return undefined; }
      const code = (error as BusinessError).code;
      const timeout = deadlineExpired || code === 2300028;
      hilog.warn(0x0303, 'UUS3C', 'request=%{public}s transport_code=%{public}d elapsed_ms=%{public}d', req.kind, code, Date.now() - started);
      return await this.command({ op: 'network_error', id: req.id, timeout: timeout });
    } finally { if (deadline >= 0) { clearTimeout(deadline); } try { task.destroy(); } catch (_) {} if (this.active === task) { this.active = undefined; } req.body = ''; req.headers = {}; }
  }
}
export const client: AuthClient = new AuthClient();
