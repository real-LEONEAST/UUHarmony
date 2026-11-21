import { RtpDiagnostics, logRtpDiagnostics } from './RtpDiagnostics';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { invoke, reserveVideoSlot, startVideoSlot, videoSlotMetrics, videoSlotStatus, stopVideoSlot, hardStopVideoSlot } from 'libs3c.so';
import { ScreenRow, DisplayReportError, CaptureConfigResponse } from './DisplayModel';
import { RemoteInput } from './MobileInput';
export interface MultiStreamView {
    screenId: number;
    open: boolean;
    renderSlot: number | null;
    generation: number | null;
    trackIndex: number | null;
    mediaEpoch: number;
    mappingConfirmed: boolean;
    videoFrameObserved: boolean;
    width: number;
    height: number;
    error: string | null;
}
interface MultiCaptureStats {
    packets_received?: number;
    access_units?: number;
    accepted?: number;
    queue_rejected?: number;
    reassembly_pli_events?: number;
    errors?: string[];
}
interface MultiTrackStats {
    trackIndex: number;
    packets: number;
    bytes: number;
    trackSeen?: boolean;
    ssrcChanges?: number;
    capture?: MultiCaptureStats;
}
interface PortraitSize { width?: number; height?: number; }
interface PortraitSetting { screenId: number; width: number; height: number; seq: number; sent: boolean; ack: boolean | null; error: string | null; beforeResolution?: PortraitSize | null; currentResolution?: PortraitSize | null; }
export interface MultiSnapshot {
    multiVideo: boolean;
    registrationAck: boolean | null;
    inventoryReceived: boolean;
    inventoryGeneration?: number;
    currentReported?: number | null;
    captureReported?: number | null;
    screens: ScreenRow[];
    streams: MultiStreamView[];
    tracks: MultiTrackStats[];
    portraitSettings?: PortraitSetting[];
    reportError?: DisplayReportError | null;
    captureConfigResponse?: CaptureConfigResponse | null;
    rtpDiagnostics?: RtpDiagnostics;
    error: string | null;
}
interface MultiEvent {
    action: string;
    screenId?: number;
    renderSlot?: number;
    generation?: number;
    scope?: string;
    token?: number;
}
interface MultiCommand {
    op: string;
    event: MultiEvent;
}
interface MultiReply {
    error?: string;
}
interface MultiInput extends RemoteInput {
    screenId: number;
    scope: string;
    token: number;
}
interface SlotMetrics {
    rendered?: number;
    renderedEpoch?: number;
    width?: number;
    height?: number;
}
interface SlotStatus {
    ready?: boolean;
    codec?: number;
    released?: boolean;
    error?: number;
}
class Renderer {
    slot: number;
    generation: number;
    surface: string;
    task: Promise<string>;
    settled: boolean = false;
    retiring: boolean = false;
    bound: boolean = false;
    constructor(slot: number, generation: number, surface: string, task: Promise<string>) { this.slot = slot; this.generation = generation; this.surface = surface; this.task = task; }
}
// Owned by the room; a window only receives a screen/slot lease and never owns the peer.
export class MultiVideoClient {
    private slots: Map<number, Renderer> = new Map();
    private queue: Promise<void> = Promise.resolve();
    private current: MultiSnapshot = { multiVideo: true, registrationAck: null, inventoryReceived: false, screens: [], streams: [], tracks: [], error: null };
    private revision: number = 0;
    private sealed: boolean = false;
    private codec: number = 0;
    get actualCodec(): number { return this.codec; }
    seal(): void { if (!this.sealed) { this.sealed = true; this.revision++; this.ownerScope = ''; this.ownerToken = 0; this.ownerScreen = -1; } }
    private token: number = 0;
    private ownerScope: string = '';
    private ownerToken: number = 0;
    private ownerScreen: number = -1;
    private pendingInputs: number = 0;
    private inputLogAt: number = 0;
    private loggedInventoryGeneration: number = -1;
    private lastReportDiagnostic: string = '';
    private lastConfigDiagnostic: string = '';
    private scopeEpoch: Map<string, number> = new Map();
    private listeners: Map<number, (value: MultiSnapshot) => void> = new Map();
    private listenerId: number = 0;
    private async request(event: MultiEvent): Promise<MultiReply> { const command: MultiCommand = { op: 'peer_multi', event: event }; return JSON.parse(await invoke(JSON.stringify(command))) as MultiReply; }
    observe(fn: (value: MultiSnapshot) => void): () => void { const id = ++this.listenerId; this.listeners.set(id, fn); fn(this.current); return () => { this.listeners.delete(id); }; }
    snapshot(): MultiSnapshot { return this.current; }
    log(state: MultiSnapshot): void {
        const report=state.reportError;
        const reportKey=report?[report.action,report.errorCode,report.typeValue].join('/'):'none';
        if(reportKey!==this.lastReportDiagnostic){this.lastReportDiagnostic=reportKey;if(report){hilog.info(0x0303,'UUDisplayFrame','kind=1 action=%{public}d errorCode=%{public}d type=%{public}d actionKnown=%{public}d codeKnown=%{public}d typeKnown=%{public}d',report.action??-1,report.errorCode??-1,report.typeValue??-1,report.action===null||report.action===undefined?0:1,report.errorCode===null||report.errorCode===undefined?0:1,report.typeValue===null||report.typeValue===undefined?0:1);}}
        const config=state.captureConfigResponse;
        const configKey=config?[config.requestSeq,config.configFlag,config.errorCode].join('/'):'none';
        if(configKey!==this.lastConfigDiagnostic){this.lastConfigDiagnostic=configKey;if(config){hilog.info(0x0303,'UUDisplayFrame','kind=2 seq=%{public}d flag=%{public}d errorCode=%{public}d seqKnown=%{public}d flagKnown=%{public}d codeKnown=%{public}d',config.requestSeq??-1,config.configFlag??-1,config.errorCode??-1,config.requestSeq===null||config.requestSeq===undefined?0:1,config.configFlag===null||config.configFlag===undefined?0:1,config.errorCode===null||config.errorCode===undefined?0:1);}}
        logRtpDiagnostics(state.rtpDiagnostics);
        for (const setting of state.portraitSettings || []) {
            hilog.info(0x0303, 'UUMultiPortrait', 'screen=%{public}d width=%{public}d height=%{public}d seq=%{public}d sent=%{public}d ack=%{public}d error=%{public}d beforeWidth=%{public}d beforeHeight=%{public}d currentWidth=%{public}d currentHeight=%{public}d', setting.screenId, setting.width, setting.height, setting.seq, setting.sent ? 1 : 0, setting.ack === null || setting.ack === undefined ? -1 : setting.ack ? 1 : 0, setting.error ? 1 : 0, setting.beforeResolution?.width || 0, setting.beforeResolution?.height || 0, setting.currentResolution?.width || 0, setting.currentResolution?.height || 0);
        }
        for (const track of state.tracks || []) {
            hilog.info(0x0303, 'UUMultiTrack', 'track=%{public}d packets=%{public}d bytes=%{public}d seen=%{public}d ssrcChanges=%{public}d', track.trackIndex, track.packets || 0, track.bytes || 0, track.trackSeen ? 1 : 0, track.ssrcChanges || 0);
        }
        const inventoryGeneration = state.inventoryGeneration || 0;
        if (state.inventoryReceived && inventoryGeneration !== this.loggedInventoryGeneration) {
            this.loggedInventoryGeneration = inventoryGeneration;
            for (const screen of state.screens) {
                hilog.info(0x0303, 'UUMultiMap', 'screen=%{public}d track=%{public}d', screen.id, screen.videoTrackIndex);
            }
        }
        for (const stream of state.streams) {
        if (stream.renderSlot === null || stream.generation === null) {
            continue;
        }
        try {
            const metrics = JSON.parse(videoSlotMetrics(stream.renderSlot, stream.generation)) as SlotMetrics;
            hilog.info(0x0303, 'UUMultiVideo', 'screen=%{public}d track=%{public}d slot=%{public}d generation=%{public}d epoch=%{public}d rendered=%{public}d width=%{public}d height=%{public}d at=%{public}d', stream.screenId, stream.trackIndex === null ? -1 : stream.trackIndex, stream.renderSlot, stream.generation, stream.mediaEpoch, metrics.rendered || 0, metrics.width || 0, metrics.height || 0, Date.now());
            const track = (state.tracks || []).find((item: MultiTrackStats) => item.trackIndex === stream.trackIndex);
            const capture = track?.capture;
            hilog.info(0x0303, 'UUMultiVideo', 'screen=%{public}d track=%{public}d epoch=%{public}d rtp=%{public}d rtpBytes=%{public}d capturePackets=%{public}d au=%{public}d accepted=%{public}d rejected=%{public}d pli=%{public}d errors=%{public}d', stream.screenId, stream.trackIndex === null ? -1 : stream.trackIndex, stream.mediaEpoch, track?.packets || 0, track?.bytes || 0, capture?.packets_received || 0, capture?.access_units || 0, capture?.accepted || 0, capture?.queue_rejected || 0, capture?.reassembly_pli_events || 0, capture?.errors?.length || 0);
        }
        catch (_) { }
    } }
    isOwner(screenId: number, scope: string): boolean { return this.ownerScreen === screenId && this.ownerScope === scope && this.ownerToken > 0; }
    private publish(value: MultiSnapshot): void { this.current = value; this.listeners.forEach((fn: (value: MultiSnapshot) => void) => { try {
        fn(value);
    }
    catch (_) { } }); }
    async poll(): Promise<void> { const run = this.revision; const value = await this.request({ action: 'snapshot' }) as MultiSnapshot; if (run === this.revision && value.multiVideo) {
        for (const stream of value.streams) {
            if (stream.renderSlot !== null && stream.generation !== null) {
                try {
                    const metrics = JSON.parse(videoSlotMetrics(stream.renderSlot, stream.generation)) as SlotMetrics;
                    if ((metrics.width || 0) > 0 && (metrics.height || 0) > 0) {
                        stream.width = metrics.width || 0;
                        stream.height = metrics.height || 0;
                    }
                }
                catch (_) { }
            }
        }
        this.publish(value);
    } }
    private enqueue(work: () => Promise<void>): Promise<void> { const next = this.queue.then(work); this.queue = next.catch(() => { }); return next; }
    private async prepare(slot: number, surface: string, run: number, requestedCodec: number): Promise<Renderer> {
        if (this.slots.has(slot) || !surface) {
            throw new Error('renderer_slot_unavailable');
        }
        const generation = reserveVideoSlot(slot);
        if (generation <= 0) {
            throw new Error('renderer_reservation_failed');
        }
        let task: Promise<string>;
        try {
            task = startVideoSlot(slot, generation, surface, requestedCodec);
        }
        catch (_) {
            hardStopVideoSlot(slot, generation);
            throw new Error('renderer_start_failed');
        }
        const renderer = new Renderer(slot, generation, surface, task);
        this.slots.set(slot, renderer);
        const settled = () => { renderer.settled = true; if (this.slots.get(slot) === renderer && renderer.retiring) {
            this.slots.delete(slot);
        } };
        task.then(settled, settled);
        const deadline = Date.now() + 10000;
        while (run === this.revision && Date.now() < deadline) {
            const status = JSON.parse(videoSlotStatus(slot, generation)) as SlotStatus;
            if (status.error || status.released) {
                throw new Error('renderer_failed');
            }
            if (status.ready) {
                if ((status.codec !== 1 && status.codec !== 2) || (requestedCodec !== 0 && status.codec !== requestedCodec)) { throw new Error('renderer_codec_mismatch'); }
                if (this.codec && status.codec !== this.codec) { throw new Error('renderer_codec_mismatch'); }
                this.codec = status.codec;
                return renderer;
            }
            await new Promise<void>((resolve: () => void) => setTimeout(resolve, 40));
        }
        throw new Error('renderer_timeout');
    }
    private async retire(slot: number): Promise<void> { const renderer = this.slots.get(slot); if (!renderer) {
        return;
    } renderer.retiring = true; hilog.info(0x0303, 'UUMultiVideo', 'release slot=%{public}d generation=%{public}d at=%{public}d', slot, renderer.generation, Date.now()); stopVideoSlot(slot, renderer.generation); let timer: number = -1; await Promise.race([renderer.task.then(() => { }, () => { }), new Promise<void>((resolve: () => void) => { timer = setTimeout(() => { hardStopVideoSlot(slot, renderer.generation); resolve(); }, 1800); })]); if (timer >= 0) {
        clearTimeout(timer);
    } if (renderer.settled && this.slots.get(slot) === renderer) {
        this.slots.delete(slot);
    } }
    async preparePrimary(surface: string, preference: number): Promise<number> {
        if (this.sealed) { throw new Error('room_closed'); }
        const run = this.revision;
        let generation = 0;
        await this.enqueue(async () => {
            try {
                const renderer = await this.prepare(0, surface, run, preference);
                if (run !== this.revision) { await this.retire(0); return; }
                generation = renderer.generation;
            } catch (_) {
                await this.retire(0);
                throw new Error('primary_renderer_prepare_failed');
            }
        });
        return generation;
    }
    open(screenId: number, slot: number, surface: string): Promise<void> { if (this.sealed) { return Promise.reject(new Error('room_closed')); } const run = this.revision; return this.enqueue(async () => { if (run !== this.revision) {
        return;
    } const existing = this.slots.get(slot);
    if (existing && (slot !== 0 || existing.bound || existing.retiring || existing.surface !== surface)) {
        throw new Error('renderer_slot_unavailable');
    }
    let opened = false; try {
        const renderer = existing || await this.prepare(slot, surface, run, this.codec);
        if (run !== this.revision) {
            await this.retire(slot);
            return;
        }
        let reply = await this.request({ action: 'open', screenId: screenId });
        if (reply.error) {
            throw new Error('screen_open_failed');
        }
        opened = true;
        reply = await this.request({ action: 'bind', screenId: screenId, renderSlot: slot, generation: renderer.generation });
        if (reply.error) {
            throw new Error('renderer_bind_failed');
        }
        renderer.bound = true;
        await this.waitForFrame(screenId, renderer, run);
    }
    catch (_) {
        if (opened && !this.sealed) {
            try {
                await this.request({ action: 'close', screenId: screenId });
            }
            catch (_) { }
        }
        await this.retire(slot);
        throw new Error('renderer_open_failed');
    } }); }
    private async waitForFrame(screenId: number, renderer: Renderer, run: number): Promise<void> {
        const deadline = Date.now() + 15000;
        while (run === this.revision && Date.now() < deadline) {
            await this.poll();
            const portrait = this.current.portraitSettings?.find((item: PortraitSetting) => item.screenId === screenId);
            if (portrait?.error) { throw new Error('portrait_setting_failed'); }
            const stream = this.current.streams.find((item) => item.screenId === screenId);
            if (stream && stream.renderSlot === renderer.slot && stream.generation === renderer.generation && stream.mappingConfirmed && stream.videoFrameObserved) {
                const metrics = JSON.parse(videoSlotMetrics(renderer.slot, renderer.generation)) as SlotMetrics;
                if ((metrics.rendered || 0) > 0 && metrics.renderedEpoch === stream.mediaEpoch && (metrics.width || 0) > 0 && (metrics.height || 0) > 0) {
                    return;
                }
            }
            await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
        }
        throw new Error('renderer_frame_timeout');
    }
    // Move the existing screen without requesting another capture; old renderer finishes before rebinding.
    move(screenId: number, slot: number, surface: string): Promise<void> {
        if (this.sealed) { return Promise.reject(new Error('room_closed')); }
        const run = this.revision;
        const previous = this.slots.get(slot)?.surface || '';
        if (this.ownerScreen === screenId) {
            this.revoke(this.ownerScope);
        }
        return this.enqueue(async () => {
            await this.retire(slot);
            if (run !== this.revision) {
                return;
            }
            try {
                const renderer = await this.prepare(slot, surface, run, this.codec);
                if (run !== this.revision) {
                    await this.retire(slot);
                    return;
                }
                const reply = await this.request({ action: 'bind', screenId: screenId, renderSlot: slot, generation: renderer.generation });
                if (reply.error) {
                    throw new Error('renderer_bind_failed');
                }
                renderer.bound = true;
                await this.waitForFrame(screenId, renderer, run);
            }
            catch (_) {
                await this.retire(slot);
                let restored = false;
                if (previous && !this.sealed && run === this.revision) {
                    try {
                        const renderer = await this.prepare(slot, previous, run, this.codec);
                        const reply = await this.request({ action: 'bind', screenId: screenId, renderSlot: slot, generation: renderer.generation });
                        if (!reply.error) {
                            renderer.bound = true;
                            await this.waitForFrame(screenId, renderer, run);
                            restored = true;
                        }
                    }
                    catch (_) {
                        restored = false;
                    }
                }
                if (!restored) {
                    await this.retire(slot);
                    if (!this.sealed) { await this.request({ action: 'close', screenId: screenId }); }
                }
                throw new Error(restored ? 'renderer_move_restored' : 'renderer_move_failed');
            }
        });
    }
    close(screenId: number, slot: number): Promise<void> { if (this.ownerScreen === screenId) {
        this.revoke(this.ownerScope);
    } return this.enqueue(async () => { const result = await this.request({ action: 'close', screenId: screenId }); await this.retire(slot); if (result.error) {
        throw new Error(result.error);
    } await this.poll(); }); }
    claim(screenId: number, scope: string, eligible: () => boolean = () => true): Promise<boolean> { if (this.sealed) { return Promise.resolve(false); } const run = this.revision, focusEpoch = this.scopeEpoch.get(scope) || 0; let accepted = false; return this.enqueue(async () => { if (run !== this.revision || focusEpoch !== (this.scopeEpoch.get(scope) || 0) || !eligible()) {
        return;
    } await this.revokeNow(); if (run !== this.revision || focusEpoch !== (this.scopeEpoch.get(scope) || 0) || !eligible()) {
        return;
    } const token = ++this.token; const reply = await this.request({ action: 'claim', screenId: screenId, scope: scope, token: token }); if (!reply.error) {
        if (run !== this.revision || focusEpoch !== (this.scopeEpoch.get(scope) || 0) || !eligible()) {
            await this.request({ action: 'revoke', scope: scope, token: token });
            return;
        }
        this.ownerScreen = screenId;
        this.ownerScope = scope;
        this.ownerToken = token;
        accepted = true;
    } }).then(() => accepted); }
    private async revokeNow(): Promise<void> { const scope = this.ownerScope, token = this.ownerToken; this.ownerScope = ''; this.ownerToken = 0; this.ownerScreen = -1; if (scope && token) {
        await this.request({ action: 'revoke', scope: scope, token: token });
    } }
    revoke(scope: string): Promise<void> { this.scopeEpoch.set(scope, (this.scopeEpoch.get(scope) || 0) + 1); if (this.ownerScope !== scope) {
        return Promise.resolve();
    } const token = this.ownerToken; this.ownerScope = ''; this.ownerToken = 0; this.ownerScreen = -1; return this.enqueue(async () => { if (token) {
        await this.request({ action: 'revoke', scope: scope, token: token });
    } }); }
    send(screenId: number, scope: string, events: RemoteInput[]): boolean { if (this.sealed) { return false; } if (this.pendingInputs >= 64) {
        this.revoke(scope).catch(() => { });
        return false;
    } if (!events.length || events.length > 256 || this.ownerScreen !== screenId || this.ownerScope !== scope || !this.ownerToken) {
        return false;
    } const token = this.ownerToken; const run = this.revision; this.pendingInputs++; this.enqueue(async () => { try {
        for (const event of events) {
            if (run !== this.revision || this.ownerScope !== scope || this.ownerToken !== token) {
                return;
            }
            const input: MultiInput = { action: event.action, button: event.button, abs_x: event.abs_x, abs_y: event.abs_y, delta_x: event.delta_x, delta_y: event.delta_y, key: event.key, content: event.content, heartbeat: event.heartbeat, index: event.index, buttons: event.buttons, left_trigger: event.left_trigger, right_trigger: event.right_trigger, left_thumb_x: event.left_thumb_x, left_thumb_y: event.left_thumb_y, right_thumb_x: event.right_thumb_x, right_thumb_y: event.right_thumb_y, screenId: screenId, scope: scope, token: token };
            const result = JSON.parse(await invoke(JSON.stringify({ op: 'peer_input', event: input }))) as MultiReply;
            if (result.error || Date.now() - this.inputLogAt >= 1000) {
                this.inputLogAt = Date.now();
                hilog.info(0x0303, 'UUMultiInput', 'send screen=%{public}d count=%{public}d error=%{public}d', screenId, events.length, result.error ? 1 : 0);
            }
            if (result.error) {
                await this.revokeNow();
                return;
            }
        }
    }
    finally {
        this.pendingInputs--;
    } }).catch(() => { this.revoke(scope).catch(() => { }); }); return true; }
    async dispose(): Promise<void> { this.seal(); await this.enqueue(async () => { await this.revokeNow(); for (const slot of Array.from(this.slots.keys())) {
        await this.retire(slot);
    } }); }
}

